import Testing
import Foundation
@testable import DevHubCore

@Suite("ClaudeReader")
struct ClaudeReaderTests {

    /// Build a fixture mimicking real ~/.claude/projects/<encoded>/<uuid>.jsonl
    private func makeFixture() throws -> (dir: URL, file: URL, sessionId: String, cwd: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claude-fixture-\(UUID().uuidString)")
        let encoded = "-Users-example-Projects-sample-workspace"
        let dir = tmp.appendingPathComponent(encoded, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sid = "ce376840-68e7-46b6-9e56-09af78f0c27e"
        let file = dir.appendingPathComponent("\(sid).jsonl")
        // 模拟真实格式：每行一个 JSON 对象，顶层有 cwd/sessionId/type/timestamp
        let lines = [
            // user message
            #"{"type":"user","cwd":"/Users/example/Projects/sample-workspace","sessionId":"\#(sid)","timestamp":"2026-07-06T10:00:00Z","message":{"role":"user","content":"审查 sample-workspace"}}"#,
            // assistant
            #"{"type":"assistant","cwd":"/Users/example/Projects/sample-workspace","sessionId":"\#(sid)","timestamp":"2026-07-06T10:01:00Z","message":{"role":"assistant","content":"开始审查"}}"#,
            // ai-title (gives session a title)
            #"{"type":"ai-title","title":"sample-workspace 审查","sessionId":"\#(sid)","timestamp":"2026-07-06T10:02:00Z"}"#,
        ]
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        return (dir, file, sid, "/Users/example/Projects/sample-workspace")
    }

    @Test("discover finds the jsonl and extracts cwd from content (not dir name)")
    func discoverReadsCwd() async throws {
        let (dir, _, sid, expectedCwd) = try makeFixture()
        let reader = ClaudeReader(projectsRoot: dir)
        let sessions = try await reader.discover()
        #expect(sessions.count == 1)
        #expect(sessions.first?.toolSessionId == sid)
        // 关键：cwd 来自 jsonl 内容，不是目录名反推
        #expect(sessions.first?.projectCwd == expectedCwd)
        #expect(sessions.first?.title == "sample-workspace 审查")
    }

    @Test("preview is first user message content")
    func previewFromFirstUser() async throws {
        let (dir, _, _, _) = try makeFixture()
        let reader = ClaudeReader(projectsRoot: dir)
        let sessions = try await reader.discover()
        #expect(sessions.first?.preview.contains("审查 sample-workspace") == true)
    }

    @Test("增量发现跳过 mtime 未变化的文件")
    func incrementalDiscoverySkipsFreshIndex() async throws {
        let (dir, file, _, _) = try makeFixture()
        let sessions = try await ClaudeReader(projectsRoot: dir)
            .discover(knownFiles: [file.path: .distantFuture])
        #expect(sessions.isEmpty)
    }

    @Test("messageCount counts user+assistant messages")
    func messageCount() async throws {
        let (dir, _, _, _) = try makeFixture()
        let reader = ClaudeReader(projectsRoot: dir)
        let sessions = try await reader.discover()
        #expect(sessions.first?.messageCount == 2)  // 1 user + 1 assistant (ai-title 不计)
    }

    @Test("load returns full messages")
    func loadFull() async throws {
        let (dir, _, sid, _) = try makeFixture()
        let reader = ClaudeReader(projectsRoot: dir)
        let detail = try await reader.load(sid)
        #expect(detail.toolSessionId == sid)
        #expect(detail.messages.count == 2)
        #expect(detail.messages.contains { $0.role == .user })
    }

    @Test("empty projects dir returns empty")
    func emptyDir() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claude-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let reader = ClaudeReader(projectsRoot: tmp)
        let sessions = try await reader.discover()
        #expect(sessions.isEmpty)
    }

    @Test("structured content arrays ignore thinking and extract text blocks")
    func structuredContentArrays() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claude-array-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let sid = "claude-array-session"
        let file = tmp.appendingPathComponent("\(sid).jsonl")
        try """
        {"type":"user","cwd":"/tmp/project","timestamp":"2026-07-19T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"结构化用户消息"}]}}
        {"type":"assistant","cwd":"/tmp/project","timestamp":"2026-07-19T10:01:00Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"internal"},{"type":"text","text":"结构化回答"}]}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let reader = ClaudeReader(projectsRoot: tmp)
        let session = try #require(try await reader.discover().first)
        let detail = try await reader.load(sid)

        #expect(session.preview == "结构化用户消息")
        #expect(session.messageCount == 2)
        #expect(detail.messages.map(\.content) == ["结构化用户消息", "结构化回答"])
    }

    @Test("load 把 assistant 的 tool_use 块拆成 .tool 消息")
    func loadExtractsToolUse() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claude-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let sid = "claude-tool-session"
        let file = tmp.appendingPathComponent("\(sid).jsonl")
        // assistant 行同时含文本与 tool_use 块
        try """
        {"type":"user","cwd":"/tmp/p","timestamp":"2026-07-19T10:00:00Z","message":{"role":"user","content":"列文件"}}
        {"type":"assistant","cwd":"/tmp/p","timestamp":"2026-07-19T10:01:00Z","message":{"role":"assistant","content":[{"type":"text","text":"好的，执行 ls"},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls -la"}}]}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let reader = ClaudeReader(projectsRoot: tmp)
        let detail = try await reader.load(sid)
        // 期望：user 文本 + assistant 文本 + tool 调用 = 3 条
        #expect(detail.messages.count == 3)
        let toolMessages = detail.messages.filter { $0.role == .tool }
        #expect(toolMessages.count == 1)
        #expect(toolMessages[0].toolName == "Bash")
        #expect(toolMessages[0].toolInput?.contains("ls -la") == true)
        // assistant 文本不应混入工具调用
        let assistantText = detail.messages.first { $0.role == .assistant }
        #expect(assistantText?.content == "好的，执行 ls")
    }

    @Test("Claude 索引跳过工具注入信封并生成标题")
    func injectedMetadataIsSkipped() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claude-envelope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let sid = "claude-envelope-session"
        let file = tmp.appendingPathComponent("\(sid).jsonl")
        try """
        {"type":"user","cwd":"/tmp/p","timestamp":"2026-08-14T10:00:00Z","message":{"role":"user","content":"<environment_context><cwd>/tmp/p</cwd></environment_context>"}}
        {"type":"user","cwd":"/tmp/p","timestamp":"2026-08-14T10:00:01Z","message":{"role":"user","content":"整理资源管理界面"}}
        {"type":"assistant","cwd":"/tmp/p","timestamp":"2026-08-14T10:00:02Z","message":{"role":"assistant","content":"好的"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let reader = ClaudeReader(projectsRoot: tmp)
        let session = try #require(try await reader.discover().first)
        let detail = try await reader.load(sid)

        #expect(session.preview == "整理资源管理界面")
        #expect(session.title == "整理资源管理界面")
        #expect(detail.messages.map(\.content) == ["整理资源管理界面", "好的"])
    }
}
