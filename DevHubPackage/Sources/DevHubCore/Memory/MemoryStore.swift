import Foundation

/// `last-session-summary.md` 的来源记录。摘要正文保持可读 Markdown，
/// 这份 sidecar 只用于判断它是否仍代表项目中最新的已索引会话。
public struct SessionSummaryMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let tool: String
    public let toolSessionId: String
    public let sessionUpdatedAt: Date
    public let generatedAt: Date

    public init(
        schemaVersion: Int = 1,
        tool: String,
        toolSessionId: String,
        sessionUpdatedAt: Date,
        generatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.tool = tool
        self.toolSessionId = toolSessionId
        self.sessionUpdatedAt = sessionUpdatedAt
        self.generatedAt = generatedAt
    }
}

/// 最近会话总结在发送前需要呈现的可信状态。
public enum SessionSummaryReviewStatus: Equatable, Sendable {
    case none
    case current
    case outdated
    case unverified

    public static func classify(
        summary: String?,
        metadata: SessionSummaryMetadata?,
        latestIndexedSessionAt: Date?
    ) -> Self {
        guard let summary,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .none
        }
        guard let metadata,
              metadata.schemaVersion == 1,
              !metadata.tool.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !metadata.toolSessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unverified
        }
        if let latestIndexedSessionAt,
           latestIndexedSessionAt > metadata.sessionUpdatedAt {
            return .outdated
        }
        return .current
    }
}

/// §4.2 §5.3B 项目记忆读写。
/// 只在 .devhub/memory/ 内操作，绝不修改项目根其他源文件。
public struct MemoryStore: Sendable {
    public let projectRoot: URL

    public init(projectRoot: URL) {
        self.projectRoot = projectRoot
    }

    private var memoryDir: URL {
        projectRoot.appendingPathComponent(".devhub").appendingPathComponent("memory")
    }

    private var contextFile: URL { memoryDir.appendingPathComponent("context.md") }
    private var summaryFile: URL { memoryDir.appendingPathComponent("last-session-summary.md") }
    private var summaryMetadataFile: URL {
        memoryDir.appendingPathComponent("last-session-summary.metadata.json")
    }

    private func ensureMemoryDir() throws {
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
    }

    public func readContext() throws -> String {
        guard FileManager.default.fileExists(atPath: contextFile.path) else { return "" }
        return try String(contentsOf: contextFile, encoding: .utf8)
    }

    public func writeContext(_ content: String) throws {
        try ensureMemoryDir()
        try content.write(to: contextFile, atomically: true, encoding: .utf8)
    }

    public func readLastSessionSummary() throws -> String? {
        guard FileManager.default.fileExists(atPath: summaryFile.path) else { return nil }
        return try String(contentsOf: summaryFile, encoding: .utf8)
    }

    public func readLastSessionSummaryMetadata() throws -> SessionSummaryMetadata? {
        guard FileManager.default.fileExists(atPath: summaryMetadataFile.path) else { return nil }
        let data = try Data(contentsOf: summaryMetadataFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(SessionSummaryMetadata.self, from: data)
    }

    public func writeLastSessionSummary(
        _ content: String,
        metadata: SessionSummaryMetadata? = nil
    ) throws {
        try ensureMemoryDir()

        // 先移除旧 sidecar，避免正文已更新但旧来源仍被误认为可信。
        if FileManager.default.fileExists(atPath: summaryMetadataFile.path) {
            try FileManager.default.removeItem(at: summaryMetadataFile)
        }
        try content.write(to: summaryFile, atomically: true, encoding: .utf8)

        if let metadata {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .secondsSince1970
            let data = try encoder.encode(metadata)
            try data.write(to: summaryMetadataFile, options: .atomic)
        }
    }
}
