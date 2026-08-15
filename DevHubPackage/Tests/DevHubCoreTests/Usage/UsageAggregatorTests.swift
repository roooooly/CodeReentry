import Testing
import Foundation
@testable import DevHubCore

@Suite("ModelPriceTable + UsageAggregator")
struct UsageAggregatorTests {

    @Test("pricing 精确匹配 + 前缀匹配 + fallback")
    func pricingLookup() {
        // 精确
        let sonnet = ModelPriceTable.pricing(for: "claude-sonnet-4-5")
        #expect(sonnet.inputPerMillion == 3)
        // 前缀（版本号后缀）
        let dated = ModelPriceTable.pricing(for: "claude-sonnet-4-20250514")
        #expect(dated.inputPerMillion == 3)
        // fallback
        let unknown = ModelPriceTable.pricing(for: "totally-unknown-model-xyz")
        #expect(unknown.inputPerMillion == ModelPriceTable.fallback.inputPerMillion)
        // overrides 优先
        let custom = ModelPricing(inputPerMillion: 99, cacheWritePerMillion: 99,
                                  cacheReadPerMillion: 99, outputPerMillion: 99)
        #expect(ModelPriceTable.pricing(for: "claude-sonnet-4-5", overrides: ["claude-sonnet-4-5": custom]).inputPerMillion == 99)
    }

    @Test("cost = tokens/1M × price")
    func costCalc() {
        // 1M tokens @ $3/1M = $3
        #expect(ModelPriceTable.cost(tokens: 1_000_000, perMillion: 3) == 3)
        // 500K tokens @ $15/1M = $7.5
        #expect(ModelPriceTable.cost(tokens: 500_000, perMillion: 15) == Decimal(string: "7.5"))
        // 0 tokens → 0
        #expect(ModelPriceTable.cost(tokens: 0, perMillion: 100) == 0)
    }

    @Test("UsageRecord.costUSD 汇总四类 token + reasoning 按 output 价")
    func recordCost() {
        let r = UsageRecord(
            tool: "claude-code", model: "claude-sonnet-4-5", cwd: "/tmp/P",
            timestamp: Date(),
            inputTokens: 1_000_000,    // $3
            cacheWriteTokens: 1_000_000, // $3.75
            cacheReadTokens: 1_000_000,  // $0.30
            outputTokens: 1_000_000,     // $15
            reasoningTokens: 0
        )
        // 3 + 3.75 + 0.3 + 15 = 22.05
        #expect(r.costUSD() == Decimal(string: "22.05"))
    }

    @Test("aggregate 按工具/模型/天/月汇总")
    func aggregateMultiDim() {
        // 用 Calendar 构造确定同一天的时间戳，避免时区漂移
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        let comps = DateComponents(year: 2025, month: 6, day: 15, hour: 10)
        let day = cal.date(from: comps)!
        let records = [
            UsageRecord(tool: "claude-code", model: "claude-sonnet-4-5", cwd: "/tmp/P",
                        timestamp: day, inputTokens: 1_000_000, cacheWriteTokens: 0,
                        cacheReadTokens: 0, outputTokens: 0, reasoningTokens: 0),
            UsageRecord(tool: "codex", model: "gpt-5.1", cwd: "/tmp/P",
                        timestamp: day.addingTimeInterval(3600), inputTokens: 0, cacheWriteTokens: 0,
                        cacheReadTokens: 0, outputTokens: 1_000_000, reasoningTokens: 0),
        ]
        let snap = UsageAggregator.aggregate(records)
        #expect(snap.perTool["claude-code"]?.costUSD == 3)   // $3/1M
        #expect(snap.perTool["codex"]?.costUSD == 10)        // gpt-5.1 output $10/1M
        #expect(snap.perModel["claude-sonnet-4-5"]?.inputTokens == 1_000_000)
        #expect(snap.perModel["gpt-5.1"]?.outputTokens == 1_000_000)
        #expect(snap.totalCostUSD == 13)
        #expect(snap.totalTokens == 2_000_000)
        // 两条同一天（10:00 与 11:00）→ perDay 单键
        #expect(snap.perDay.count == 1)
        // 未传 projectPaths → perProject 为空（cwd 无归桶目标）
        #expect(snap.perProject.isEmpty)
    }

    @Test("aggregate 传 projectPaths 时按 cwd 归桶到 perProject")
    func aggregatePerProject() {
        let records = [
            UsageRecord(tool: "x", model: "m", cwd: "/Users/example-a/P", timestamp: Date(),
                        inputTokens: 1, cacheWriteTokens: 0, cacheReadTokens: 0,
                        outputTokens: 0, reasoningTokens: 0),
            UsageRecord(tool: "x", model: "m", cwd: "/Users/example-a/P/sub/src", timestamp: Date(),
                        inputTokens: 1, cacheWriteTokens: 0, cacheReadTokens: 0,
                        outputTokens: 0, reasoningTokens: 0),
            UsageRecord(tool: "x", model: "m", cwd: "/other", timestamp: Date(),
                        inputTokens: 1, cacheWriteTokens: 0, cacheReadTokens: 0,
                        outputTokens: 0, reasoningTokens: 0),
        ]
        let snap = UsageAggregator.aggregate(records, projectPaths: ["/Users/example-a/P", "/Users/example-a/P/sub"])
        // /Users/example-a/P/sub/src 匹配最长前缀 /Users/example-a/P/sub
        #expect(snap.perProject["/Users/example-a/P"]?.totalTokens == 1)
        #expect(snap.perProject["/Users/example-a/P/sub"]?.totalTokens == 1)
        // /other 未匹配任何项目 → 不进 perProject
        #expect(snap.perProject.count == 2)
    }

    @Test("groupByProject 最长前缀匹配")
    func groupByProject() {
        let paths = ["/Users/example-a/P", "/Users/example-a/P/sub"]
        let records = [
            UsageRecord(tool: "x", model: "m", cwd: "/Users/example-a/P", timestamp: Date(),
                        inputTokens: 1, cacheWriteTokens: 0, cacheReadTokens: 0,
                        outputTokens: 0, reasoningTokens: 0),
            UsageRecord(tool: "x", model: "m", cwd: "/Users/example-a/P/sub/src", timestamp: Date(),
                        inputTokens: 1, cacheWriteTokens: 0, cacheReadTokens: 0,
                        outputTokens: 0, reasoningTokens: 0),
            UsageRecord(tool: "x", model: "m", cwd: "/other", timestamp: Date(),
                        inputTokens: 1, cacheWriteTokens: 0, cacheReadTokens: 0,
                        outputTokens: 0, reasoningTokens: 0),
        ]
        let grouped = UsageAggregator.groupByProject(records, projectPaths: paths)
        // /Users/example-a/P/sub/src 应匹配最长前缀 /Users/example-a/P/sub
        #expect(grouped["/Users/example-a/P"]?.count == 1)
        #expect(grouped["/Users/example-a/P/sub"]?.count == 1)
        #expect(grouped[nil]?.count == 1)
    }
}
