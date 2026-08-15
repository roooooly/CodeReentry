import Foundation

/// AI 会话消息角色（§5.3A）。
public enum MessageRole: String, Sendable, Equatable {
    case user
    case assistant
    case system
    case tool
}

/// Reader 发现的会话摘要（§5.3A）。cwd 来自 jsonl 内容，不靠目录名反推。
public struct DiscoveredSession: Sendable, Equatable {
    public let tool: String
    public let toolSessionId: String
    public let sourcePath: String
    public let projectCwd: String
    public let startedAt: Date
    public let updatedAt: Date
    /// Exact count when non-negative; `-1` means the large-file metadata scan
    /// intentionally skipped a full count to keep indexing resource-bounded.
    public let messageCount: Int
    public let title: String?
    public let preview: String

    public init(tool: String, toolSessionId: String, sourcePath: String, projectCwd: String,
                startedAt: Date, updatedAt: Date, messageCount: Int, title: String?, preview: String) {
        self.tool = tool
        self.toolSessionId = toolSessionId
        self.sourcePath = sourcePath
        self.projectCwd = projectCwd
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.title = title
        self.preview = preview
    }

    /// 与 SessionIndex.identityKey 一致："<tool>:<toolSessionId>"
    public var identityKey: String { "\(tool):\(toolSessionId)" }
}

/// 会话中的一条消息（§5.3A）。
///
/// `toolName`/`toolInput` 仅在 `role == .tool`（工具调用）时填充：
/// 正文查看器据此渲染可折叠的工具调用块。摘要路径不产生 `.tool` 消息，
/// 故这两个字段对 `SummaryExtractor` 透明。
public struct SessionMessage: Sendable, Equatable {
    public let role: MessageRole
    public let content: String
    public let timestamp: Date
    /// 工具调用的名称（如 "Bash"），仅 `.tool` 角色非 nil。
    public let toolName: String?
    /// 工具调用的参数（格式化的 JSON 字符串），仅 `.tool` 角色非 nil。
    public let toolInput: String?

    public init(role: MessageRole, content: String, timestamp: Date,
                toolName: String? = nil, toolInput: String? = nil) {
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.toolName = toolName
        self.toolInput = toolInput
    }
}

/// 完整会话详情（§5.3A），用于 summary 生成与展示。
public struct SessionDetail: Sendable, Equatable {
    public let tool: String
    public let toolSessionId: String
    public let cwd: String
    public let startedAt: Date
    public let messages: [SessionMessage]
    /// True when the bounded reader omitted an oversized line or stopped after
    /// reaching its byte/message/text budget. The original file remains the SoT.
    public let isTruncated: Bool

    public init(tool: String, toolSessionId: String, cwd: String,
                startedAt: Date, messages: [SessionMessage], isTruncated: Bool = false) {
        self.tool = tool
        self.toolSessionId = toolSessionId
        self.cwd = cwd
        self.startedAt = startedAt
        self.messages = messages
        self.isTruncated = isTruncated
    }
}

/// AI 会话 reader 协议（§5.3A）。每个工具（Claude Code、codex）实现一份。
public protocol SessionReader: Sendable {
    var toolId: String { get }
    func discover() async throws -> [DiscoveredSession]
    /// Incremental discovery hook. Keys are already-indexed source paths and
    /// values are their last successful index times.
    func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession]
    func load(_ id: String) async throws -> SessionDetail
}

public extension SessionReader {
    /// Readers backed by small metadata stores can keep their existing full
    /// discovery behavior. File-backed readers override this method.
    func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession] {
        try await discover()
    }
}
