import Foundation

/// 用量聚合结果（纯值类型，§订阅用量与成本）。
public struct UsageSnapshot: Sendable, Equatable {
    public let perTool: [String: ToolUsage]       // tool → 汇总
    public let perModel: [String: ToolUsage]      // model → 汇总
    public let perProject: [String: ToolUsage]    // project path → 汇总（按 cwd 匹配）
    public let perDay: [DateString: ToolUsage]    // YYYY-MM-DD → 汇总
    public let perMonth: [DateString: ToolUsage]  // YYYY-MM → 汇总
    public let totalCostUSD: Decimal
    public let totalTokens: Int
    public let generatedAt: Date

    public struct ToolUsage: Sendable, Equatable {
        public let costUSD: Decimal
        public let inputTokens: Int
        public let cacheWriteTokens: Int
        public let cacheReadTokens: Int
        public let outputTokens: Int
        public let reasoningTokens: Int
        public var totalTokens: Int {
            inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens + reasoningTokens
        }
        public init(costUSD: Decimal, inputTokens: Int, cacheWriteTokens: Int,
                    cacheReadTokens: Int, outputTokens: Int, reasoningTokens: Int) {
            self.costUSD = costUSD
            self.inputTokens = inputTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.cacheReadTokens = cacheReadTokens
            self.outputTokens = outputTokens
            self.reasoningTokens = reasoningTokens
        }
        public static let zero = ToolUsage(costUSD: 0, inputTokens: 0, cacheWriteTokens: 0,
                                           cacheReadTokens: 0, outputTokens: 0, reasoningTokens: 0)
        public func merging(_ other: ToolUsage) -> ToolUsage {
            ToolUsage(
                costUSD: costUSD + other.costUSD,
                inputTokens: inputTokens + other.inputTokens,
                cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
                cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
                outputTokens: outputTokens + other.outputTokens,
                reasoningTokens: reasoningTokens + other.reasoningTokens
            )
        }
    }

    public typealias DateString = String

    public init(perTool: [String: ToolUsage], perModel: [String: ToolUsage],
                perProject: [String: ToolUsage] = [:],
                perDay: [DateString: ToolUsage], perMonth: [DateString: ToolUsage],
                totalCostUSD: Decimal, totalTokens: Int, generatedAt: Date) {
        self.perTool = perTool
        self.perModel = perModel
        self.perProject = perProject
        self.perDay = perDay
        self.perMonth = perMonth
        self.totalCostUSD = totalCostUSD
        self.totalTokens = totalTokens
        self.generatedAt = generatedAt
    }
}

/// 用量聚合器（纯函数，便于测试）。
public enum UsageAggregator {

    /// 把原始 records 聚合成多维度 snapshot。
    /// - Parameters:
    ///   - priceOverrides: 用户自定义单价（默认空，用 ModelPriceTable.defaults）。
    ///   - projectPaths: 注册项目的根路径列表；非空时按 cwd 最长前缀匹配归桶到 perProject。
    public static func aggregate(
        _ records: [UsageRecord],
        priceOverrides: [String: ModelPricing] = [:],
        projectPaths: [String] = [],
        now: Date = Date()
    ) -> UsageSnapshot {
        var perTool: [String: UsageSnapshot.ToolUsage] = [:]
        var perModel: [String: UsageSnapshot.ToolUsage] = [:]
        var perProject: [String: UsageSnapshot.ToolUsage] = [:]
        var perDay: [String: UsageSnapshot.ToolUsage] = [:]
        var perMonth: [String: UsageSnapshot.ToolUsage] = [:]
        var totalCost: Decimal = .zero
        var totalTokens = 0

        let dayFmt = DateFormatter()
        dayFmt.locale = Locale(identifier: "en_US_POSIX")
        dayFmt.dateFormat = "yyyy-MM-dd"
        let monthFmt = DateFormatter()
        monthFmt.locale = Locale(identifier: "en_US_POSIX")
        monthFmt.dateFormat = "yyyy-MM"

        for r in records {
            let cost = r.costUSD(overrides: priceOverrides)
            let usage = UsageSnapshot.ToolUsage(
                costUSD: cost,
                inputTokens: r.inputTokens,
                cacheWriteTokens: r.cacheWriteTokens,
                cacheReadTokens: r.cacheReadTokens,
                outputTokens: r.outputTokens,
                reasoningTokens: r.reasoningTokens
            )
            perTool[r.tool, default: .zero] = perTool[r.tool, default: .zero].merging(usage)
            perModel[r.model, default: .zero] = perModel[r.model, default: .zero].merging(usage)
            if let projectPath = matchProject(cwd: r.cwd, in: projectPaths) {
                perProject[projectPath, default: .zero] = perProject[projectPath, default: .zero].merging(usage)
            }
            let dayKey = dayFmt.string(from: r.timestamp)
            perDay[dayKey, default: .zero] = perDay[dayKey, default: .zero].merging(usage)
            let monthKey = monthFmt.string(from: r.timestamp)
            perMonth[monthKey, default: .zero] = perMonth[monthKey, default: .zero].merging(usage)
            totalCost += cost
            totalTokens += r.totalTokens
        }
        return UsageSnapshot(
            perTool: perTool,
            perModel: perModel,
            perProject: perProject,
            perDay: perDay,
            perMonth: perMonth,
            totalCostUSD: totalCost,
            totalTokens: totalTokens,
            generatedAt: now
        )
    }

    /// 按 cwd 匹配归到某个项目根（与 SessionAggregator 同样的最长前缀规则）。
    /// 返回 [项目路径: [UsageRecord]]，未匹配的进 nil 键。
    public static func groupByProject(
        _ records: [UsageRecord],
        projectPaths: [String]
    ) -> [String?: [UsageRecord]] {
        var bucket: [String?: [UsageRecord]] = [:]
        for r in records {
            let matched = matchProject(cwd: r.cwd, in: projectPaths)
            bucket[matched, default: []].append(r)
        }
        return bucket
    }

    /// 匹配规则：精确相等 OR cwd 是项目子目录（最长前缀优先）。
    static func matchProject(cwd: String, in paths: [String]) -> String? {
        guard !cwd.isEmpty else { return nil }
        var best: String?
        for path in paths {
            if cwd == path { return path }
            if cwd.hasPrefix(path + "/") {
                if best == nil || path.count > best!.count { best = path }
            }
        }
        return best
    }
}
