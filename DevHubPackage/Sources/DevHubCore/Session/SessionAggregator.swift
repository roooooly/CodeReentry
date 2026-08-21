import Foundation
import SwiftData

public struct SessionAggregationMetrics: Sendable, Equatable {
    public let preparationMilliseconds: Int
    public let discoveryMilliseconds: Int
    public let projectMatchingMilliseconds: Int
    public let writingMilliseconds: Int
    public let writePreparationMilliseconds: Int
    public let writeModelMutationMilliseconds: Int
    public let writeSaveMilliseconds: Int
    public let writeCacheMilliseconds: Int

    public init(
        preparationMilliseconds: Int,
        discoveryMilliseconds: Int,
        projectMatchingMilliseconds: Int,
        writingMilliseconds: Int,
        writePreparationMilliseconds: Int,
        writeModelMutationMilliseconds: Int,
        writeSaveMilliseconds: Int,
        writeCacheMilliseconds: Int
    ) {
        self.preparationMilliseconds = preparationMilliseconds
        self.discoveryMilliseconds = discoveryMilliseconds
        self.projectMatchingMilliseconds = projectMatchingMilliseconds
        self.writingMilliseconds = writingMilliseconds
        self.writePreparationMilliseconds = writePreparationMilliseconds
        self.writeModelMutationMilliseconds = writeModelMutationMilliseconds
        self.writeSaveMilliseconds = writeSaveMilliseconds
        self.writeCacheMilliseconds = writeCacheMilliseconds
    }
}

/// §5.3A 聚合器——组合所有 reader，按 cwd 归到 Project，写 SessionIndex。
public struct SessionAggregator: Sendable {
    public let readers: [SessionReader]

    public init(readers: [SessionReader]) {
        self.readers = readers
    }

    @MainActor
    @discardableResult
    public func aggregate(
        writer: SessionIndexWriter,
        modelContext: ModelContext
    ) async throws -> SessionAggregationMetrics {
        // `indexedAt` is deliberately separate from the session's display date:
        // a source file only needs reparsing when its mtime is newer than the
        // last successful index. This turns subsequent refreshes into a cheap
        // directory walk instead of rereading every historical JSONL.
        let preparationStart = ContinuousClock.now
        let knownFiles = try await writer.prepareForRefresh()
        let preparationMilliseconds = Self.milliseconds(since: preparationStart)

        // 收集所有 reader 的发现。单个工具格式变化时保留其他 reader 的结果，
        // 但最终仍显式抛出失败，让 UI 不会把“不兼容”误报成“没有会话”。
        var allDiscovered: [DiscoveredSession] = []
        var failures: [SessionReaderFailure] = []
        for reader in readers {
            do {
                let found = try await reader.discover(knownFiles: knownFiles)
                allDiscovered.append(contentsOf: found)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append(SessionReaderFailure(
                    toolId: reader.toolId,
                    message: error.localizedDescription
                ))
            }
        }
        // dedupe by identityKey
        var seen: Set<String> = []
        var unique: [DiscoveredSession] = []
        for s in allDiscovered {
            if seen.insert(s.identityKey).inserted {
                unique.append(s)
            }
        }
        let discoveryMilliseconds = Self.milliseconds(since: preparationStart)
            - preparationMilliseconds
        // 查所有 projects 用于按 cwd 匹配。这里只取 Sendable 的 (cwd → stableId) 映射，
        // 避免跨 actor 传递非 Sendable 的 @Model 实例（Swift 6 严格并发）。
        let projects = try modelContext.fetch(FetchDescriptor<Project>())
        let projectPaths = projects.map {
            (path: ($0.path as NSString).standardizingPath, stableId: $0.stableId)
        }
        var exactProjectsByRawPath: [String: String] = [:]
        for project in projects where exactProjectsByRawPath[project.path] == nil {
            exactProjectsByRawPath[project.path] = project.stableId
        }
        var exactProjectsByPath: [String: String] = [:]
        for project in projectPaths where exactProjectsByPath[project.path] == nil {
            exactProjectsByPath[project.path] = project.stableId
        }
        let nestedProjectPaths = projectPaths.sorted { $0.path.count > $1.path.count }
        var projectMatches: [String: String] = [:]
        for s in unique {
            guard !s.projectCwd.isEmpty else { continue }
            if let stableId = exactProjectsByRawPath[s.projectCwd] {
                projectMatches[s.identityKey] = stableId
                continue
            }
            let normalizedCwd = (s.projectCwd as NSString).standardizingPath
            let stableId = exactProjectsByPath[normalizedCwd] ?? nestedProjectPaths.first {
                normalizedCwd.hasPrefix($0.path + "/")
            }?.stableId
            if let stableId {
                projectMatches[s.identityKey] = stableId
            }
        }
        let projectMatchingMilliseconds = Self.milliseconds(since: preparationStart)
            - preparationMilliseconds
            - discoveryMilliseconds
        // 关系也在同一 ModelActor 批次内解析；一次保存整个增量，避免每行两次事务。
        let writingStart = ContinuousClock.now
        let writeMetrics = try await writer.upsertBatch(
            unique,
            projectStableIdsByIdentity: projectMatches
        )
        let writingMilliseconds = Self.milliseconds(since: writingStart)
        if !failures.isEmpty {
            throw SessionAggregationError.readerFailures(failures)
        }
        return SessionAggregationMetrics(
            preparationMilliseconds: preparationMilliseconds,
            discoveryMilliseconds: discoveryMilliseconds,
            projectMatchingMilliseconds: projectMatchingMilliseconds,
            writingMilliseconds: writingMilliseconds,
            writePreparationMilliseconds: writeMetrics.preparationMilliseconds,
            writeModelMutationMilliseconds: writeMetrics.modelMutationMilliseconds,
            writeSaveMilliseconds: writeMetrics.saveMilliseconds,
            writeCacheMilliseconds: writeMetrics.cacheMilliseconds
        )
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        return Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Older indexes may contain a launch envelope or an empty ZCode fallback.
    /// Reparse those once. A negative message count proves the current bounded
    /// reader already inspected the large file and found no displayable user
    /// text, so repeating that pass on every refresh only creates allocation
    /// pressure without producing new information.
    static func shouldForceReindex(
        tool: String,
        title: String?,
        preview: String,
        messageCount: Int
    ) -> Bool {
        if SessionDisplayText.needsReindex(title: title, preview: preview) {
            return true
        }
        return tool == "zcode"
            && messageCount >= 0
            && SessionDisplayText.displayTitle(title: title, preview: preview) == nil
            && SessionDisplayText.displayPreview(preview) == nil
    }

    /// 精确匹配项目根目录，也允许会话 cwd 位于项目子目录中。
    /// 多个项目嵌套时选择路径最长（最具体）的项目。
    static func projectStableId(
        for cwd: String,
        among projects: [(path: String, stableId: String)]
    ) -> String? {
        guard !cwd.isEmpty else { return nil }
        let normalizedCwd = (cwd as NSString).standardizingPath
        return projects
            .compactMap { project -> (stableId: String, length: Int)? in
                let path = (project.path as NSString).standardizingPath
                guard normalizedCwd == path || normalizedCwd.hasPrefix(path + "/") else { return nil }
                return (project.stableId, path.count)
            }
            .max { $0.length < $1.length }?
            .stableId
    }
}

public struct SessionReaderFailure: Sendable, Equatable {
    public let toolId: String
    public let message: String

    public init(toolId: String, message: String) {
        self.toolId = toolId
        self.message = message
    }
}

public enum SessionAggregationError: LocalizedError, Sendable, Equatable {
    case readerFailures([SessionReaderFailure])

    public var errorDescription: String? {
        switch self {
        case .readerFailures(let failures):
            let details = failures.map { "\($0.toolId)：\($0.message)" }.joined(separator: "\n")
            return "部分会话来源刷新失败；其他来源已更新。\n\(details)"
        }
    }
}
