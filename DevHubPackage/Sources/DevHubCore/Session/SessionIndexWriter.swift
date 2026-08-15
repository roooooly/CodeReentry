import Foundation
import SwiftData

/// SessionIndex 的不可变快照（Sendable），用于跨 actor 传递读取结果（§9 Swift 6 严格并发）。
/// @Model 实例本身非 Sendable，不能从 ModelActor 跨 isolation 返回。
public struct SessionIndexSnapshot: Sendable, Equatable {
    public let identityKey: String
    public let tool: String
    public let toolSessionId: String
    public let sourcePath: String
    public let projectCwd: String
    public let startedAt: Date
    public let updatedAt: Date
    public let messageCount: Int
    public let title: String?
    public let preview: String
    public let indexedAt: Date

    public init(from s: SessionIndex) {
        self.identityKey = s.identityKey
        self.tool = s.tool
        self.toolSessionId = s.toolSessionId
        self.sourcePath = s.sourcePath
        self.projectCwd = s.projectCwd
        self.startedAt = s.startedAt
        self.updatedAt = s.updatedAt
        self.messageCount = s.messageCount
        self.title = s.title
        self.preview = s.preview
        self.indexedAt = s.indexedAt
    }
}

/// 串行化 SessionIndex 写入（§9 关键并发问题）。
/// 所有 reader 把发现的会话交给 writer；writer 用 ModelActor 串行化，保证 identityKey 唯一。
@ModelActor
public actor SessionIndexWriter {

    /// Applies one incremental discovery pass with a single fetch and save.
    /// The previous per-row upsert/link/save sequence caused hundreds of
    /// SwiftData transactions and a large transient allocation spike.
    public func upsertBatch(
        _ sessions: [DiscoveredSession],
        projectStableIdsByIdentity: [String: String]
    ) throws {
        guard !sessions.isEmpty else { return }

        let existingRows = try modelContext.fetch(FetchDescriptor<SessionIndex>())
        // Build these maps defensively. A pre-existing store created by an older
        // build may contain duplicate logical keys; `Dictionary(uniqueKeysWithValues:)`
        // would turn that recoverable data issue into a process crash.
        var existingByKey: [String: SessionIndex] = [:]
        for row in existingRows {
            if let current = existingByKey[row.identityKey], current.indexedAt >= row.indexedAt {
                continue
            }
            existingByKey[row.identityKey] = row
        }
        let projects = try modelContext.fetch(FetchDescriptor<Project>())
        var projectsByStableId: [String: Project] = [:]
        for project in projects where projectsByStableId[project.stableId] == nil {
            projectsByStableId[project.stableId] = project
        }
        let indexedAt = Date()

        for discovered in sessions {
            let row: SessionIndex
            if let existing = existingByKey[discovered.identityKey] {
                row = existing
                row.sourcePath = discovered.sourcePath
                // Metadata-only readers may not know cwd. Preserve explicit
                // manual classification in that case.
                if !discovered.projectCwd.isEmpty {
                    row.projectCwd = discovered.projectCwd
                }
                row.startedAt = discovered.startedAt
                row.updatedAt = discovered.updatedAt
                row.messageCount = discovered.messageCount
                row.title = discovered.title
                row.preview = discovered.preview
                row.indexedAt = indexedAt
            } else {
                row = SessionIndex(
                    tool: discovered.tool,
                    toolSessionId: discovered.toolSessionId,
                    sourcePath: discovered.sourcePath,
                    projectCwd: discovered.projectCwd,
                    startedAt: discovered.startedAt,
                    updatedAt: discovered.updatedAt,
                    messageCount: discovered.messageCount,
                    title: discovered.title,
                    preview: discovered.preview,
                    indexedAt: indexedAt
                )
                modelContext.insert(row)
                existingByKey[discovered.identityKey] = row
            }

            if let stableId = projectStableIdsByIdentity[discovered.identityKey],
               let project = projectsByStableId[stableId] {
                row.project = project
            } else if !discovered.projectCwd.isEmpty {
                row.project = nil
            }
        }
        try modelContext.save()
    }

    public func upsert(
        tool: String,
        toolSessionId: String,
        sourcePath: String,
        projectCwd: String,
        startedAt: Date,
        updatedAt: Date,
        messageCount: Int,
        title: String?,
        preview: String,
        project: Project? = nil
    ) throws {
        let key = "\(tool):\(toolSessionId)"
        let descriptor = FetchDescriptor<SessionIndex>(
            predicate: #Predicate { $0.identityKey == key }
        )
        let existing = try modelContext.fetch(descriptor).first
        if let existing {
            existing.sourcePath = sourcePath
            // ZCode/Kimi 的本地元数据不含 cwd。若用户已经在 DevHub 中手动归类，
            // 后续聚合不能用 reader 的空字符串把该归类覆盖掉。
            if !projectCwd.isEmpty {
                existing.projectCwd = projectCwd
            }
            existing.startedAt = startedAt
            existing.updatedAt = updatedAt
            existing.messageCount = messageCount
            existing.title = title
            existing.preview = preview
            existing.indexedAt = Date()
            if let p = project { existing.project = p }
        } else {
            let s = SessionIndex(
                tool: tool, toolSessionId: toolSessionId,
                sourcePath: sourcePath, projectCwd: projectCwd,
                startedAt: startedAt, updatedAt: updatedAt,
                messageCount: messageCount, title: title, preview: preview,
                project: project
            )
            modelContext.insert(s)
        }
        try modelContext.save()
    }

    public func all() -> [SessionIndexSnapshot] {
        let descriptor = FetchDescriptor<SessionIndex>(sortBy: [.init(\.updatedAt, order: .reverse)])
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows.map(SessionIndexSnapshot.init)
    }

    @discardableResult
    public func removeStale() throws -> Int {
        let all = try modelContext.fetch(FetchDescriptor<SessionIndex>())
        var count = 0
        let fm = FileManager.default
        for s in all where !fm.fileExists(atPath: s.sourcePath) {
            modelContext.delete(s)
            count += 1
        }
        try modelContext.save()
        return count
    }

    /// 按 identityKey + projectStableId 关联 SessionIndex ↔ Project（§5.3A）。
    /// 在 writer actor 内部解析关系，避免跨 actor 传递非 Sendable 的 @Model 实例。
    /// 返回是否成功关联。
    @discardableResult
    public func linkProject(identityKey: String, projectStableId: String?) throws -> Bool {
        guard let stableId = projectStableId else { return false }
        let sessionDescriptor = FetchDescriptor<SessionIndex>(
            predicate: #Predicate { $0.identityKey == identityKey }
        )
        guard let session = try modelContext.fetch(sessionDescriptor).first else { return false }
        let projectDescriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.stableId == stableId }
        )
        guard let project = try modelContext.fetch(projectDescriptor).first else { return false }
        session.project = project
        try modelContext.save()
        return true
    }

    /// 把会话显式归类到一个已注册项目，并同步写入项目路径。
    ///
    /// 与 `linkProject` 的区别是：该方法用于用户操作，必须同时保存 cwd，
    /// 这样不提供 cwd 的 reader（目前是 ZCode/Kimi 元数据）再次聚合时也能保留归类。
    @discardableResult
    public func assignProject(identityKey: String, projectStableId: String) throws -> Bool {
        let sessionDescriptor = FetchDescriptor<SessionIndex>(
            predicate: #Predicate { $0.identityKey == identityKey }
        )
        guard let session = try modelContext.fetch(sessionDescriptor).first else { return false }
        let projectDescriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.stableId == projectStableId }
        )
        guard let project = try modelContext.fetch(projectDescriptor).first else { return false }
        session.projectCwd = project.path
        session.project = project
        try modelContext.save()
        return true
    }

    /// 清除项目关系。保留 reader 提供的非空 cwd，方便用户看到未注册的来源路径。
    @discardableResult
    public func unlinkProject(identityKey: String) throws -> Bool {
        let descriptor = FetchDescriptor<SessionIndex>(
            predicate: #Predicate { $0.identityKey == identityKey }
        )
        guard let session = try modelContext.fetch(descriptor).first else { return false }
        session.project = nil
        try modelContext.save()
        return true
    }

    /// 手动更新某 SessionIndex 的 projectCwd（§5.3 zcode 无 cwd，需用户绑定）。
    @discardableResult
    public func updateCwd(identityKey: String, cwd: String) throws -> Bool {
        let desc = FetchDescriptor<SessionIndex>(predicate: #Predicate { $0.identityKey == identityKey })
        guard let session = try modelContext.fetch(desc).first else { return false }
        session.projectCwd = cwd
        try modelContext.save()
        return true
    }

    /// 按 identityKey 取 SessionIndex 的 cwd（测试/校验用）。
    public func fetchCwd(identityKey: String) throws -> String? {
        let desc = FetchDescriptor<SessionIndex>(predicate: #Predicate { $0.identityKey == identityKey })
        return try modelContext.fetch(desc).first?.projectCwd
    }

    /// 测试与诊断用：读取当前项目归类。
    public func fetchProjectStableId(identityKey: String) throws -> String? {
        let desc = FetchDescriptor<SessionIndex>(predicate: #Predicate { $0.identityKey == identityKey })
        return try modelContext.fetch(desc).first?.project?.stableId
    }
}
