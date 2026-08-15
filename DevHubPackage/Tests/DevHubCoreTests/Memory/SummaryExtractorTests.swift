import Testing
import Foundation
@testable import DevHubCore

@Suite("SummaryExtractor")
struct SummaryExtractorTests {

    @Test("extracts first user messages as summary")
    func extractsSummary() async throws {
        let detail = SessionDetail(
            tool: "claude-code", toolSessionId: "x", cwd: "/p",
            startedAt: Date(),
            messages: [
                SessionMessage(role: .user, content: "审查 sample-workspace", timestamp: Date()),
                SessionMessage(role: .assistant, content: "ok", timestamp: Date()),
                SessionMessage(role: .user, content: "重点看登录", timestamp: Date()),
            ]
        )
        let summary = SummaryExtractor.extractSummary(from: detail, maxUserMessages: 3)
        #expect(summary.contains("审查 sample-workspace"))
        #expect(summary.contains("重点看登录"))
    }

    @Test("respects maxUserMessages limit")
    func limit() async throws {
        let msgs = (0..<10).map { i in
            SessionMessage(role: .user, content: "msg \(i)", timestamp: Date())
        }
        let detail = SessionDetail(tool: "x", toolSessionId: "y", cwd: "/", startedAt: Date(), messages: msgs)
        let summary = SummaryExtractor.extractSummary(from: detail, maxUserMessages: 3)
        #expect(summary.contains("msg 0"))
        #expect(summary.contains("msg 2"))
        #expect(!summary.contains("msg 3"))
    }

    @Test("empty messages returns placeholder")
    func empty() async throws {
        let detail = SessionDetail(tool: "x", toolSessionId: "y", cwd: "/", startedAt: Date(), messages: [])
        let summary = SummaryExtractor.extractSummary(from: detail, maxUserMessages: 3)
        #expect(summary.contains("无用户消息"))
    }
}
