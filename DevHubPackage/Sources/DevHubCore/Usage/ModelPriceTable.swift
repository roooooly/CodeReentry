import Foundation

/// 单个模型的单价（每 1M tokens，美元 USD）。
///
/// 来源：Anthropic / OpenAI 官方定价页。Pro/Max 订阅用户按 token 估算"等价成本"，
/// 实际订阅是定额付费——这里的 cost 是"如果按 API 计费会是多少"，作为消耗规模的可比指标，
/// 而非真实扣款金额。UI 会明确标注"估算"。
public struct ModelPricing: Sendable, Equatable, Codable {
    public let inputPerMillion: Decimal
    public let cacheWritePerMillion: Decimal   // cache_creation，通常 1.25× input
    public let cacheReadPerMillion: Decimal    // cache_read，通常 0.1× input
    public let outputPerMillion: Decimal

    public init(inputPerMillion: Decimal, cacheWritePerMillion: Decimal,
                cacheReadPerMillion: Decimal, outputPerMillion: Decimal) {
        self.inputPerMillion = inputPerMillion
        self.cacheWritePerMillion = cacheWritePerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
        self.outputPerMillion = outputPerMillion
    }
}

/// 模型 → 单价表（§订阅用量与成本）。
/// 内置主流模型默认价（USD/1M tokens）；用户可在设置里覆盖（后续阶段接入 AppSettings）。
public enum ModelPriceTable {

    /// 内置默认价。键为模型名（大小写敏感匹配 JSONL 里的 message.model）。
    /// 缺失模型按"未知模型"兜底（保守中等价）。
    public static let defaults: [String: ModelPricing] = [
        // Anthropic Claude（2024-2025 定价）
        "claude-opus-4-1":            ModelPricing(inputPerMillion: 15,  cacheWritePerMillion: 18.75, cacheReadPerMillion: 1.5,  outputPerMillion: 75),
        "claude-opus-4-5":            ModelPricing(inputPerMillion: 5,   cacheWritePerMillion: 6.25,  cacheReadPerMillion: 0.5,  outputPerMillion: 25),
        "claude-sonnet-4-5":          ModelPricing(inputPerMillion: 3,   cacheWritePerMillion: 3.75,  cacheReadPerMillion: 0.3,  outputPerMillion: 15),
        "claude-sonnet-4-20250514":   ModelPricing(inputPerMillion: 3,   cacheWritePerMillion: 3.75,  cacheReadPerMillion: 0.3,  outputPerMillion: 15),
        "claude-3-7-sonnet-20250219": ModelPricing(inputPerMillion: 3,   cacheWritePerMillion: 3.75,  cacheReadPerMillion: 0.3,  outputPerMillion: 15),
        "claude-3-5-haiku-20241022":  ModelPricing(inputPerMillion: 0.8, cacheWritePerMillion: 1,     cacheReadPerMillion: 0.08, outputPerMillion: 4),
        "claude-haiku-4-5":           ModelPricing(inputPerMillion: 1,   cacheWritePerMillion: 1.25,  cacheReadPerMillion: 0.1,  outputPerMillion: 5),
        // GLM（智谱）
        "glm-4.6":                    ModelPricing(inputPerMillion: 0.6, cacheWritePerMillion: 0.6,   cacheReadPerMillion: 0.06, outputPerMillion: 2.2),
        "glm-5.2":                    ModelPricing(inputPerMillion: 0.5, cacheWritePerMillion: 0.5,   cacheReadPerMillion: 0.05, outputPerMillion: 1.8),
        // OpenAI（Codex 常用）
        "gpt-5.5":                    ModelPricing(inputPerMillion: 1.25, cacheWritePerMillion: 1.25, cacheReadPerMillion: 0.125, outputPerMillion: 10),
        "gpt-5.6-sol":                ModelPricing(inputPerMillion: 1.25, cacheWritePerMillion: 1.25, cacheReadPerMillion: 0.125, outputPerMillion: 10),
        "gpt-5.1":                    ModelPricing(inputPerMillion: 1.25, cacheWritePerMillion: 1.25, cacheReadPerMillion: 0.125, outputPerMillion: 10),
        "gpt-4.1":                    ModelPricing(inputPerMillion: 2,   cacheWritePerMillion: 2,     cacheReadPerMillion: 0.2,   outputPerMillion: 8),
        "gpt-4.1-mini":               ModelPricing(inputPerMillion: 0.4, cacheWritePerMillion: 0.4,   cacheReadPerMillion: 0.04,  outputPerMillion: 1.6),
        "o3":                         ModelPricing(inputPerMillion: 2,   cacheWritePerMillion: 2,     cacheReadPerMillion: 0.5,   outputPerMillion: 8),
    ]

    /// 未在表中找到模型时的保守兜底价（中等水平）。
    public static let fallback = ModelPricing(
        inputPerMillion: 3, cacheWritePerMillion: 3.75,
        cacheReadPerMillion: 0.3, outputPerMillion: 15
    )

    /// 取某模型单价；优先 overrides，其次内置默认，最后 fallback。
    public static func pricing(for model: String, overrides: [String: ModelPricing] = [:]) -> ModelPricing {
        if let o = overrides[model] { return o }
        // 精确匹配
        if let d = defaults[model] { return d }
        // 前缀/子串匹配（处理版本号后缀如 "claude-sonnet-4-5-20250929"）
        let lower = model.lowercased()
        for (key, value) in defaults {
            if lower.hasPrefix(key) || lower.contains(key) { return value }
        }
        return fallback
    }

    /// 把 token 数 × 单价折算成美元成本。
    /// tokens 是原始计数，pricing 是 per 1M。
    public static func cost(tokens: Int, perMillion: Decimal) -> Decimal {
        guard tokens > 0 else { return .zero }
        return Decimal(tokens) * perMillion / 1_000_000
    }
}
