import Foundation

/// 单条用量记录（统一 Claude/Codex 解析后的形态，§订阅用量与成本）。
public struct UsageRecord: Sendable, Equatable {
    public let tool: String            // "claude-code" / "codex"
    public let model: String
    public let cwd: String
    public let timestamp: Date
    public let inputTokens: Int
    public let cacheWriteTokens: Int   // Claude cache_creation / Codex 无（记 0）
    public let cacheReadTokens: Int    // Claude cache_read / Codex cached_input
    public let outputTokens: Int
    public let reasoningTokens: Int    // Codex reasoning_output_tokens / Claude 无（记 0）

    public init(tool: String, model: String, cwd: String, timestamp: Date,
                inputTokens: Int, cacheWriteTokens: Int, cacheReadTokens: Int,
                outputTokens: Int, reasoningTokens: Int) {
        self.tool = tool
        self.model = model
        self.cwd = cwd
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
    }

    /// 该条记录的估算成本（USD），按 ModelPriceTable。
    public func costUSD(overrides: [String: ModelPricing] = [:]) -> Decimal {
        let p = ModelPriceTable.pricing(for: model, overrides: overrides)
        return ModelPriceTable.cost(tokens: inputTokens, perMillion: p.inputPerMillion)
            + ModelPriceTable.cost(tokens: cacheWriteTokens, perMillion: p.cacheWritePerMillion)
            + ModelPriceTable.cost(tokens: cacheReadTokens, perMillion: p.cacheReadPerMillion)
            + ModelPriceTable.cost(tokens: outputTokens, perMillion: p.outputPerMillion)
            // reasoning tokens 按 output 价计（OpenAI 对 reasoning 按 completion 计费）
            + ModelPriceTable.cost(tokens: reasoningTokens, perMillion: p.outputPerMillion)
    }

    public var totalTokens: Int {
        inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens + reasoningTokens
    }
}

/// Codex 订阅额度快照（5h/7d 滚动窗口），从最近一条 token_count 事件抽取。
public struct CodexRateLimitSnapshot: Sendable, Equatable {
    public let primaryUsedPercent: Double    // 5h 窗口
    public let primaryWindowMinutes: Int
    public let primaryResetsAt: Date?
    public let secondaryUsedPercent: Double  // 7d 窗口
    public let secondaryWindowMinutes: Int
    public let secondaryResetsAt: Date?

    public init(primaryUsedPercent: Double, primaryWindowMinutes: Int, primaryResetsAt: Date?,
                secondaryUsedPercent: Double, secondaryWindowMinutes: Int, secondaryResetsAt: Date?) {
        self.primaryUsedPercent = primaryUsedPercent
        self.primaryWindowMinutes = primaryWindowMinutes
        self.primaryResetsAt = primaryResetsAt
        self.secondaryUsedPercent = secondaryUsedPercent
        self.secondaryWindowMinutes = secondaryWindowMinutes
        self.secondaryResetsAt = secondaryResetsAt
    }
}
