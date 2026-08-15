import Testing
import Foundation
import DevHubCore
@testable import DevHub

@Suite("SessionDetailViewModel")
@MainActor
struct SessionDetailViewModelTests {

    private func makeSession(tool: String = "claude-code", messageCount: Int = 2) -> SessionIndex {
        SessionIndex(
            tool: tool,
            toolSessionId: UUID().uuidString,
            sourcePath: "/tmp/s.jsonl",
            projectCwd: "/tmp/P",
            startedAt: Date(),
            updatedAt: Date(),
            messageCount: messageCount,
            title: "Test session",
            preview: "hello"
        )
    }

    @Test("无 reader 时进入 unreadable 态（如 Kimi）")
    func noReaderUnreadable() async {
        let vm = SessionDetailViewModel(session: makeSession(tool: "kimi"), reader: nil)
        await vm.load()
        if case .unreadable = vm.state {
            // ok
        } else {
            Issue.record("expected unreadable state, got \(vm.state)")
        }
        #expect(vm.messages.isEmpty)
    }

    @Test("有 reader 时加载消息为 loaded 态")
    func loadedWithReader() async throws {
        let stub = StubSessionReader(
            detail: SessionDetail(
                tool: "claude-code", toolSessionId: "s1", cwd: "/tmp/P",
                startedAt: Date(),
                messages: [
                    SessionMessage(role: .user, content: "你好", timestamp: Date()),
                    SessionMessage(role: .assistant, content: "你好，有什么可以帮你？", timestamp: Date())
                ]
            )
        )
        let vm = SessionDetailViewModel(session: makeSession(), reader: stub)
        await vm.load()
        guard case .loaded = vm.state else {
            Issue.record("expected loaded"); return
        }
        #expect(vm.messages.count == 2)
        #expect(vm.messages[0].role == .user)
        #expect(vm.messages[1].role == .assistant)
    }

    @Test("reader 抛错进入 failed 态")
    func failedOnReaderError() async {
        struct BoomReader: SessionReader {
            let toolId = "claude-code"
            func discover() async throws -> [DiscoveredSession] { [] }
            func load(_ id: String) async throws -> SessionDetail { throw NSError(domain: "x", code: 1) }
        }
        let vm = SessionDetailViewModel(session: makeSession(), reader: BoomReader())
        await vm.load()
        if case .failed = vm.state {
            // ok
        } else {
            Issue.record("expected failed state, got \(vm.state)")
        }
    }
}

/// 测试桩 reader：返回固定 detail。
private struct StubSessionReader: SessionReader {
    let toolId = "claude-code"
    let detail: SessionDetail
    func discover() async throws -> [DiscoveredSession] { [] }
    func load(_ id: String) async throws -> SessionDetail { detail }
}
