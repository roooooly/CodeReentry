import Testing
import Foundation
@testable import DevHubCore

@Suite("SessionReader protocol types")
struct SessionReaderProtocolTests {

    @Test("DiscoveredSession carries identity + cwd + timestamps")
    func discoveredFields() {
        let s = DiscoveredSession(
            tool: "codex",
            toolSessionId: "019f2852-0902-7f33-af68-7168135f5af2",
            sourcePath: "/Users/example/.codex/sessions/2026/07/03/rollout-x.jsonl",
            projectCwd: "/Users/example/Projects/sample-workspace",
            startedAt: Date(),
            updatedAt: Date(),
            messageCount: 12,
            title: "审查 sample-workspace",
            preview: "审查一下本地 sample-workspace 网站"
        )
        #expect(s.identityKey == "codex:019f2852-0902-7f33-af68-7168135f5af2")
    }

    @Test("SessionMessage has role + content + timestamp")
    func sessionMessage() {
        let m = SessionMessage(role: .user, content: "hi", timestamp: Date())
        #expect(m.role == .user)
    }

    @Test("SessionDetail carries all messages")
    func sessionDetail() {
        let detail = SessionDetail(
            tool: "claude-code", toolSessionId: "x",
            cwd: "/tmp/P", startedAt: Date(),
            messages: [SessionMessage(role: .user, content: "hi", timestamp: Date())]
        )
        #expect(detail.messages.count == 1)
    }

    @Test("fake reader conforms to protocol")
    func fakeReaderConformance() {
        let r = FakeReader()
        #expect(r.toolId == "fake")
    }
}

struct FakeReader: SessionReader {
    let toolId = "fake"
    func discover() async throws -> [DiscoveredSession] { [] }
    func load(_ id: String) async throws -> SessionDetail {
        SessionDetail(tool: "fake", toolSessionId: id, cwd: "/",
                      startedAt: Date(), messages: [])
    }
}
