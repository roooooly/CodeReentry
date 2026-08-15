import Testing
import Foundation
import DevHubCore
@testable import DevHub

@Suite("UsageScanner")
@MainActor
struct UsageScannerTests {

    @Test("injectSnapshotForTesting 注入快照与额度")
    func inject() {
        let scanner = UsageScanner()
        let snap = UsageAggregator.aggregate([
            UsageRecord(tool: "claude-code", model: "claude-sonnet-4-5", cwd: "/tmp/P",
                        timestamp: Date(), inputTokens: 1_000_000, cacheWriteTokens: 0,
                        cacheReadTokens: 0, outputTokens: 0, reasoningTokens: 0)
        ])
        scanner.injectSnapshotForTesting(
            snap,
            rateLimit: CodexRateLimitSnapshot(
                primaryUsedPercent: 50, primaryWindowMinutes: 300, primaryResetsAt: nil,
                secondaryUsedPercent: 10, secondaryWindowMinutes: 10080, secondaryResetsAt: nil
            )
        )
        #expect(scanner.snapshot?.totalCostUSD == 3)        // 1M input @ $3
        #expect(scanner.snapshot?.totalTokens == 1_000_000)
        #expect(scanner.codexRateLimit?.primaryUsedPercent == 50)
        #expect(scanner.lastScannedAt != nil)
    }

    @Test("refreshIfStale 跳过近期扫描（注入后立即调用不重扫）")
    func refreshIfStaleSkips() async {
        // 用空临时根目录构造 scanner，扫描得到空快照
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-scanner-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let claude = ClaudeUsageReader(projectsRoot: tmp.appendingPathComponent("claude"))
        let codex = CodexUsageReader(rootURL: tmp.appendingPathComponent("codex"), model: "gpt-5.1")
        let scanner = UsageScanner(claudeReader: claude, codexReader: codex)

        scanner.injectSnapshotForTesting(.init(
            perTool: [:], perModel: [:], perDay: [:], perMonth: [:],
            totalCostUSD: 42, totalTokens: 0, generatedAt: Date()
        ))
        await scanner.refreshIfStale()
        // 注入后立即 refreshIfStale 应被跳过，注入的 totalCostUSD 保留
        #expect(scanner.snapshot?.totalCostUSD == 42)
    }
}
