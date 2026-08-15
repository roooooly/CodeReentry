import Foundation
import SwiftData

/// §5.3A 聚合器——组合所有 reader，按 cwd 归到 Project，写 SessionIndex。
public struct SessionAggregator: Sendable {
    public let readers: [SessionReader]

    public init(readers: [SessionReader]) {
        self.readers = readers
    }

    @MainActor
    public func aggregate(writer: SessionIndexWriter, modelContext: ModelContext) async throws {
        // `indexedAt` is deliberately separate from the session's display date:
        // a source file only needs reparsing when its mtime is newer than the
        // last successful index. This turns subsequent refreshes into a cheap
        // directory walk instead of rereading every historical JSONL.
        let indexed = await writer.all()
        var knownFiles: [String: Date] = [:]
        for session in indexed where !session.sourcePath.isEmpty {
            if Self.shouldForceReindex(
                tool: session.tool,
                title: session.title,
                preview: session.preview,
                messageCount: session.messageCount
            ) {
                continue
            }
            let previous = knownFiles[session.sourcePath] ?? .distantPast
            knownFiles[session.sourcePath] = max(previous, session.indexedAt)
        }

        // 收集所有 reader 的发现
        var allDiscovered: [DiscoveredSession] = []
        for reader in readers {
            let found = (try? await reader.discover(knownFiles: knownFiles)) ?? []
            allDiscovered.append(contentsOf: found)
        }
        // dedupe by identityKey
        var seen: Set<String> = []
        var unique: [DiscoveredSession] = []
        for s in allDiscovered {
            if !seen.contains(s.identityKey) {
                seen.insert(s.identityKey)
                unique.append(s)
            }
        }
        // 查所有 projects 用于按 cwd 匹配。这里只取 Sendable 的 (cwd → stableId) 映射，
        // 避免跨 actor 传递非 Sendable 的 @Model 实例（Swift 6 严格并发）。
        let projects = try modelContext.fetch(FetchDescriptor<Project>())
        let projectPaths = projects.map { (path: $0.path, stableId: $0.stableId) }
        var projectMatches: [String: String] = [:]
        for s in unique {
            if let stableId = Self.projectStableId(for: s.projectCwd, among: projectPaths) {
                projectMatches[s.identityKey] = stableId
            }
        }
        // 关系也在同一 ModelActor 批次内解析；一次保存整个增量，避免每行两次事务。
        try await writer.upsertBatch(unique, projectStableIdsByIdentity: projectMatches)
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
