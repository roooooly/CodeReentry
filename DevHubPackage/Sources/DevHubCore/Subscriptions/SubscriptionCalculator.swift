import Foundation

extension SubscriptionCycle {
    /// 把任意 cycle 的金额归一到月度（yearly 除以 12）。
    public func monthlyAmount(_ amount: Decimal) -> Decimal {
        switch self {
        case .monthly: return amount
        case .yearly:  return amount / 12
        }
    }

    /// 归一到年度。
    public func yearlyAmount(_ amount: Decimal) -> Decimal {
        switch self {
        case .monthly: return amount * 12
        case .yearly:  return amount
        }
    }
}

/// 订阅金额的轻量投影，便于纯函数测试（不依赖 SwiftData 上下文）。
/// 生产代码从 `[Subscription]` map 出 snapshot。
public struct SubscriptionSnapshot: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let provider: String
    public let amount: Decimal
    public let currency: String
    public let cycle: SubscriptionCycle
    public let nextRenewal: Date
    public let reminderDaysBefore: Int
    public let notes: String?
    public let projectId: UUID?
    public let active: Bool

    public init(id: UUID, name: String, provider: String, amount: Decimal,
                currency: String, cycle: SubscriptionCycle, nextRenewal: Date,
                reminderDaysBefore: Int, notes: String? = nil,
                projectId: UUID? = nil, active: Bool) {
        self.id = id
        self.name = name
        self.provider = provider
        self.amount = amount
        self.currency = currency
        self.cycle = cycle
        self.nextRenewal = nextRenewal
        self.reminderDaysBefore = reminderDaysBefore
        self.notes = notes
        self.projectId = projectId
        self.active = active
    }

    /// 从 SwiftData @Model 构造（在 @Model 仍存活的 context 上调用）。
    public init(_ sub: Subscription) {
        self.id = sub.id
        self.name = sub.name
        self.provider = sub.provider
        self.amount = sub.amount
        self.currency = sub.currency
        self.cycle = sub.cycle
        self.nextRenewal = sub.nextRenewal
        self.reminderDaysBefore = sub.reminderDaysBefore
        self.notes = sub.notes
        self.projectId = sub.project?.id
        self.active = sub.active
    }
}

/// 订阅金额计算（§5.4）。**不能跨币种 SUM**——按 currency 分组。
public enum SubscriptionCalculator {

    /// 月度归一后按币种分组求和。
    public static func monthlyTotalsByCurrency(_ snapshots: [SubscriptionSnapshot]) -> [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for s in snapshots where s.active {
            totals[s.currency, default: 0] += s.cycle.monthlyAmount(s.amount)
        }
        return totals
    }

    /// 年度归一后按币种分组求和。
    public static func yearlyTotalsByCurrency(_ snapshots: [SubscriptionSnapshot]) -> [String: Decimal] {
        var totals: [String: Decimal] = [:]
        for s in snapshots where s.active {
            totals[s.currency, default: 0] += s.cycle.yearlyAmount(s.amount)
        }
        return totals
    }

    /// 可选：用用户手动录入的参考汇率换算成单一展示币种。
    /// referenceRates key 为源币种 → value 为"1 源币种 = N 展示币种"。
    /// 无汇率则跳过该币种（不做隐式换算，spec §5.4）。
    public static func monthlyTotalInDisplayCurrency(
        _ snapshots: [SubscriptionSnapshot],
        displayCurrency: String,
        referenceRates: [String: Decimal]
    ) -> Decimal {
        var total: Decimal = 0
        for (currency, monthly) in monthlyTotalsByCurrency(snapshots) {
            if currency == displayCurrency {
                total += monthly
            } else if let rate = referenceRates[currency] {
                total += monthly * rate
            }
        }
        return total
    }
}
