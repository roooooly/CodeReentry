import Foundation
import SwiftData

/// 会话索引（§4.1 §5.3A §9）。
/// 设计原则：原始 JSONL 是事实来源，本模型是可重建索引——删光也能从 JSONL 全量重建（§4.2 §4.3）。
/// 唯一约束：identityKey = "<tool>:<toolSessionId>"（macOS 14 用 ModelActor 串行化保证，Task 11）。
@Model
public final class SessionIndex {
    @Attribute(.unique) public var id: UUID
    public var tool: String
    public var toolSessionId: String
    @Attribute(.unique) public var identityKey: String
    public var sourcePath: String
    public var projectCwd: String
    public var startedAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    public var title: String?
    public var preview: String
    public var indexedAt: Date

    public var project: Project?

    public init(
        id: UUID = UUID(),
        tool: String,
        toolSessionId: String,
        sourcePath: String,
        projectCwd: String,
        startedAt: Date,
        updatedAt: Date,
        messageCount: Int,
        title: String?,
        preview: String,
        indexedAt: Date = Date(),
        project: Project? = nil
    ) {
        self.id = id
        self.tool = tool
        self.toolSessionId = toolSessionId
        self.identityKey = "\(tool):\(toolSessionId)"
        self.sourcePath = sourcePath
        self.projectCwd = projectCwd
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.title = title
        self.preview = preview
        self.indexedAt = indexedAt
        self.project = project
    }

    /// 同 identityKey 取 updatedAt 最新的（§9 启动时 dedupe 清理）。
    public static func dedupe(_ sessions: [SessionIndex]) -> [SessionIndex] {
        var latest: [String: SessionIndex] = [:]
        for s in sessions {
            if let existing = latest[s.identityKey] {
                if s.updatedAt > existing.updatedAt { latest[s.identityKey] = s }
            } else {
                latest[s.identityKey] = s
            }
        }
        return Array(latest.values)
    }
}
