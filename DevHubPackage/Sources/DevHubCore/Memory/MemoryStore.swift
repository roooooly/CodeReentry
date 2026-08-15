import Foundation

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

    public func writeLastSessionSummary(_ content: String) throws {
        try ensureMemoryDir()
        try content.write(to: summaryFile, atomically: true, encoding: .utf8)
    }
}
