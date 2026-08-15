import Testing
import Foundation
@testable import DevHubCore

@Suite("ZcodeReader discover")
struct ZcodeReaderTests {

    func makeFixtureDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("rollout", isDirectory: true),
            withIntermediateDirectories: true)
        return dir
    }

    @Test("discover 列出非 subagent 文件，跳过 subagent")
    func discoverSkipsSubagent() async throws {
        let dir = try makeFixtureDir()
        let rollout = dir.appendingPathComponent("rollout")
        try """
        {"sessionId":"sess_aaaa-1111","startedAt":"2026-07-01T10:00:00Z","type":"main"}
        {"sessionId":"sess_aaaa-1111","startedAt":"2026-07-01T10:00:01Z","type":"main"}
        """.write(to: rollout.appendingPathComponent("model-io-sess_aaaa-1111.jsonl"), atomically: true, encoding: .utf8)
        try """
        {"sessionId":"sess_subagent_x","startedAt":"2026-07-01T11:00:00Z","type":"subagent"}
        """.write(to: rollout.appendingPathComponent("model-io-sess_subagent_x.jsonl"), atomically: true, encoding: .utf8)

        let reader = ZcodeReader(rootDir: dir)
        let sessions = try await reader.discover()
        #expect(sessions.count == 1)
        #expect(sessions.first?.toolSessionId == "sess_aaaa-1111")
    }

    @Test("startedAt 取首条记录")
    func startedAtFromFirstLine() async throws {
        let dir = try makeFixtureDir()
        let rollout = dir.appendingPathComponent("rollout")
        try """
        {"sessionId":"sess_bbbb-2222","startedAt":"2026-07-01T10:00:00Z","type":"main"}
        {"sessionId":"sess_bbbb-2222","startedAt":"2026-07-01T12:00:00Z","type":"main"}
        """.write(to: rollout.appendingPathComponent("model-io-sess_bbbb-2222.jsonl"), atomically: true, encoding: .utf8)
        let reader = ZcodeReader(rootDir: dir)
        let sessions = try await reader.discover()
        let expected = ISO8601DateFormatter().date(from: "2026-07-01T10:00:00Z")
        #expect(sessions.first?.startedAt == expected)
    }

    @Test("cwd 永远空（由调用方绑定）")
    func cwdAlwaysEmpty() async throws {
        let dir = try makeFixtureDir()
        let rollout = dir.appendingPathComponent("rollout")
        try """
        {"sessionId":"sess_cccc-3333","startedAt":"2026-07-01T10:00:00Z","type":"main"}
        """.write(to: rollout.appendingPathComponent("model-io-sess_cccc-3333.jsonl"), atomically: true, encoding: .utf8)
        let reader = ZcodeReader(rootDir: dir)
        let sessions = try await reader.discover()
        #expect(sessions.first?.projectCwd == "")
    }

    @Test("identityKey 为 zcode:<sessionId>")
    func identityKey() async throws {
        let dir = try makeFixtureDir()
        let rollout = dir.appendingPathComponent("rollout")
        try """
        {"sessionId":"sess_dddd-4444","startedAt":"2026-07-01T10:00:00Z","type":"main"}
        """.write(to: rollout.appendingPathComponent("model-io-sess_dddd-4444.jsonl"), atomically: true, encoding: .utf8)
        let reader = ZcodeReader(rootDir: dir)
        let sessions = try await reader.discover()
        #expect(sessions.first?.identityKey == "zcode:sess_dddd-4444")
    }

    @Test("preview 取首条 user 消息")
    func previewFromFirstUserMessage() async throws {
        let dir = try makeFixtureDir()
        let rollout = dir.appendingPathComponent("rollout")
        let line = """
        {"sessionId":"sess_eeee","startedAt":"2026-07-01T10:00:00Z","type":"main","request":{"body":{"messages":[{"role":"user","content":"帮我修 bug"}]}}}
        """
        try line.write(to: rollout.appendingPathComponent("model-io-sess_eeee.jsonl"), atomically: true, encoding: .utf8)
        let reader = ZcodeReader(rootDir: dir)
        let sessions = try await reader.discover()
        #expect(sessions.first?.preview.contains("帮我修 bug") == true)
    }

    @Test("preview 跳过 system 并支持结构化 user content")
    func previewSkipsSystemAndReadsStructuredContent() async throws {
        let dir = try makeFixtureDir()
        let rollout = dir.appendingPathComponent("rollout")
        let line = """
        {"sessionId":"sess_structured","startedAt":"2026-07-01T10:00:00.000Z","request":{"body":{"messages":[{"role":"system","content":"You are ZCode, an interactive coding agent"},{"role":"user","content":[{"type":"text","text":"优化资源占用"}]}]}}}
        """
        try line.write(
            to: rollout.appendingPathComponent("model-io-sess_structured.jsonl"),
            atomically: true,
            encoding: .utf8
        )

        let sessions = try await ZcodeReader(rootDir: dir).discover()
        #expect(sessions.first?.title == "优化资源占用")
        #expect(sessions.first?.preview == "优化资源占用")
    }

    @Test("detail 使用最新请求快照而不重复累加历史")
    func detailUsesLatestRequestSnapshot() async throws {
        let dir = try makeFixtureDir()
        let rollout = dir.appendingPathComponent("rollout")
        let file = rollout.appendingPathComponent("model-io-sess_latest.jsonl")
        let content = """
        {"startedAt":"2026-07-01T10:00:00.000Z","request":{"body":{"messages":[{"role":"user","content":"第一问"}]}},"response":{"text":"第一答"}}
        {"startedAt":"2026-07-01T10:01:00.000Z","request":{"body":{"messages":[{"role":"user","content":"第一问"},{"role":"assistant","content":"第一答"},{"role":"user","content":"第二问"}]}},"response":{"text":"第二答"}}
        """
        try content.write(to: file, atomically: true, encoding: .utf8)

        let detail = try await ZcodeReader(rootDir: dir).load("sess_latest")
        #expect(detail.messages.map(\.content) == ["第一问", "第一答", "第二问", "第二答"])
        #expect(detail.isTruncated == false)
    }

    @Test("增量发现跳过 mtime 未变化的文件")
    func incrementalDiscoverySkipsKnownFile() async throws {
        let dir = try makeFixtureDir()
        let rollout = dir.appendingPathComponent("rollout")
        let file = rollout.appendingPathComponent("model-io-sess_known.jsonl")
        try """
        {"startedAt":"2026-07-01T10:00:00Z","request":{"body":{"messages":[{"role":"user","content":"已索引"}]}}}
        """.write(to: file, atomically: true, encoding: .utf8)
        let mtime = try file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate ?? Date()

        let sessions = try await ZcodeReader(rootDir: dir).discover(knownFiles: [file.path: mtime])
        #expect(sessions.isEmpty)
    }

    @Test("rollout 目录不存在返回空")
    func noRolloutDir() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("zcode-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let reader = ZcodeReader(rootDir: dir)
        let sessions = try await reader.discover()
        #expect(sessions.isEmpty)
    }
}
