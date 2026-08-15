import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("SessionIndex model")
struct SessionIndexTests {

    @Test("identityKey combines tool and toolSessionId")
    func identityKeyFormat() {
        let s = SessionIndex(
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

    @Test("identityKey single field uniqueness anchor")
    func uniqueAttributePresent() {
        let s = SessionIndex(
            tool: "claude-code", toolSessionId: "abc",
            sourcePath: "/tmp/a.jsonl", projectCwd: "/tmp",
            startedAt: Date(), updatedAt: Date(), messageCount: 0, title: nil, preview: ""
        )
        #expect(s.identityKey == "claude-code:abc")
    }

    @Test("preview is the P0 search target field")
    func previewIsSearchField() {
        let s = SessionIndex(
            tool: "claude-code", toolSessionId: "x",
            sourcePath: "/tmp", projectCwd: "/tmp",
            startedAt: Date(), updatedAt: Date(), messageCount: 0,
            title: "T", preview: "审查 sample-workspace"
        )
        #expect(s.preview.contains("sample-workspace"))
    }

    @Test("dedupe keeps latest by updatedAt")
    func dedupeKeepsLatest() {
        let base = Date()
        let a = SessionIndex(tool: "codex", toolSessionId: "same", sourcePath: "/a", projectCwd: "/p",
            startedAt: base, updatedAt: base, messageCount: 1, title: nil, preview: "a")
        let b = SessionIndex(tool: "codex", toolSessionId: "same", sourcePath: "/b", projectCwd: "/p",
            startedAt: base, updatedAt: base.addingTimeInterval(60), messageCount: 2, title: nil, preview: "b")
        let deduped = SessionIndex.dedupe([a, b])
        #expect(deduped.count == 1)
        #expect(deduped.first?.sourcePath == "/b")
    }
}
