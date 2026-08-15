import Testing
import Foundation
@testable import DevHubCore

@Suite("CodexReader")
struct CodexReaderTests {

    private func makeFixture() throws -> (root: URL, file: URL, sessionId: String) {
        // 模拟 ~/.codex/sessions/2026/07/03/rollout-<ts>-<uuid>.jsonl
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("codex-fixture-\(UUID().uuidString)")
        let dir = tmp.appendingPathComponent("sessions/2026/07/03", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sid = "019f2852-0902-7f33-af68-7168135f5af2"
        let file = dir.appendingPathComponent("rollout-2026-07-03T22-11-32-\(sid).jsonl")
        // codex 格式：每行 {timestamp, type, payload}。payload 可以是 cwd 字符串或对象。
        let lines = [
            #"{"timestamp":"2026-07-03T22:11:32Z","type":"session_meta","payload":{"cwd":"/Users/example/Projects/sample-workspace"}}"#,
            #"{"timestamp":"2026-07-03T22:12:00Z","type":"message","payload":{"role":"user","content":"开始审查"}}"#,
            #"{"timestamp":"2026-07-03T22:13:00Z","type":"message","payload":{"role":"assistant","content":"好的"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return (tmp, file, sid)
    }

    @Test("discover finds rollout jsonl and extracts cwd from payload")
    func discoverReadsCwd() async throws {
        let (root, _, sid) = try makeFixture()
        let reader = CodexReader(rootURL: root)
        let sessions = try await reader.discover()
        #expect(sessions.count == 1)
        #expect(sessions.first?.toolSessionId == sid)
        #expect(sessions.first?.projectCwd == "/Users/example/Projects/sample-workspace")
    }

    @Test("sessionId parsed from filename")
    func sessionIdFromFilename() async throws {
        let (root, _, sid) = try makeFixture()
        let reader = CodexReader(rootURL: root)
        let sessions = try await reader.discover()
        #expect(sessions.first?.toolSessionId == sid)
    }

    @Test("增量发现跳过 mtime 未变化的文件")
    func incrementalDiscoverySkipsFreshIndex() async throws {
        let (root, file, _) = try makeFixture()
        let reader = CodexReader(rootURL: root)
        let sessions = try await reader.discover(knownFiles: [file.path: .distantFuture])
        #expect(sessions.isEmpty)
    }

    @Test("优先使用 Codex session_index 的线程标题")
    func sessionIndexProvidesTitle() async throws {
        let (root, _, sid) = try makeFixture()
        try """
        {"id":"\(sid)","thread_name":"索引里的标题","updated_at":"2026-07-03T22:13:00.000Z"}
        """.write(
            to: root.appendingPathComponent("session_index.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        let session = try #require(try await CodexReader(rootURL: root).discover().first)
        #expect(session.title == "索引里的标题")
    }

    @Test("messageCount counts message-type lines")
    func messageCount() async throws {
        let (root, _, _) = try makeFixture()
        let reader = CodexReader(rootURL: root)
        let sessions = try await reader.discover()
        #expect(sessions.first?.messageCount == 2)
    }

    @Test("load returns full detail")
    func loadDetail() async throws {
        let (root, _, sid) = try makeFixture()
        let reader = CodexReader(rootURL: root)
        let detail = try await reader.load(sid)
        #expect(detail.messages.count == 2)
        #expect(detail.cwd == "/Users/example/Projects/sample-workspace")
    }

    @Test("discovers from archived_sessions/ too")
    func archivedSessions() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("codex-arch-\(UUID().uuidString)")
        let archDir = tmp.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: archDir, withIntermediateDirectories: true)
        let sid = "abc-archived-001"
        let file = archDir.appendingPathComponent("rollout-2026-06-01T10-00-00-\(sid).jsonl")
        try """
        {"timestamp":"2026-06-01T10:00:00Z","type":"session_meta","payload":{"cwd":"/Users/example/Projects/old"}}
        {"timestamp":"2026-06-01T10:01:00Z","type":"message","payload":{"role":"user","content":"old session"}}
        """.data(using: .utf8)!.write(to: file)

        let reader = CodexReader(rootURL: tmp)
        let sessions = try await reader.discover()
        #expect(sessions.count == 1)
        #expect(sessions.first?.toolSessionId == sid)
        #expect(sessions.first?.projectCwd == "/Users/example/Projects/old")
    }

    @Test("structured content arrays produce preview and detail text")
    func structuredContentArrays() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("codex-array-\(UUID().uuidString)")
        let dir = tmp.appendingPathComponent("sessions/2026/07/19", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sid = "019f-array-content"
        let file = dir.appendingPathComponent("rollout-2026-07-19T10-00-00-\(sid).jsonl")
        try """
        {"timestamp":"2026-07-19T10:00:00Z","type":"session_meta","payload":{"cwd":"/tmp/project"}}
        {"timestamp":"2026-07-19T10:01:00Z","type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"数组里的用户请求"}]}}
        {"timestamp":"2026-07-19T10:02:00Z","type":"response_item","payload":{"role":"assistant","content":[{"type":"thinking","text":"不应展示"},{"type":"output_text","text":"数组里的回答"}]}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let reader = CodexReader(rootURL: tmp)
        let session = try #require(try await reader.discover().first)
        let detail = try await reader.load(sid)

        #expect(session.preview == "数组里的用户请求")
        #expect(session.messageCount == 2)
        #expect(detail.messages.map(\.content) == ["数组里的用户请求", "数组里的回答"])
    }

    @Test("Codex 启动元数据不会覆盖真实用户请求")
    func injectedMetadataIsSkipped() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("codex-envelope-\(UUID().uuidString)")
        let dir = tmp.appendingPathComponent("sessions/2026/08/14", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sid = "019f-envelope-content"
        let file = dir.appendingPathComponent("rollout-2026-08-14T10-00-00-\(sid).jsonl")
        try """
        {"timestamp":"2026-08-14T10:00:00Z","type":"session_meta","payload":{"cwd":"/tmp/project"}}
        {"timestamp":"2026-08-14T10:00:01Z","type":"response_item","payload":{"role":"user","content":"<recommended_plugins>list</recommended_plugins><environment_context><cwd>/tmp/project</cwd></environment_context>"}}
        {"timestamp":"2026-08-14T10:00:02Z","type":"response_item","payload":{"role":"user","content":"优化 DevHub 的内存与界面"}}
        {"timestamp":"2026-08-14T10:00:03Z","type":"response_item","payload":{"role":"assistant","content":"开始检查"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let reader = CodexReader(rootURL: tmp)
        let session = try #require(try await reader.discover().first)
        let detail = try await reader.load(sid)

        #expect(session.preview == "优化 DevHub 的内存与界面")
        #expect(session.title == "优化 DevHub 的内存与界面")
        #expect(detail.messages.map(\.content) == ["优化 DevHub 的内存与界面", "开始检查"])
    }
}
