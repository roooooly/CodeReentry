import Foundation
import SwiftData

public enum SubscriptionCycle: String, Codable, Sendable, CaseIterable {
    case monthly
    case yearly
}

/// 订阅（§4.1 §5.4）。amount 是 Decimal，内存 reduce 聚合（不依赖 SQL SUM，见 §5.4 §12.7）。
@Model
public final class Subscription {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var provider: String
    public var amount: Decimal
    public var currency: String
    public var cycleRaw: String
    public var nextRenewal: Date
    public var notes: String?
    public var reminderDaysBefore: Int
    public var active: Bool

    @Relationship
    public var project: Project?

    public var cycle: SubscriptionCycle {
        get { SubscriptionCycle(rawValue: cycleRaw) ?? .monthly }
        set { cycleRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        name: String,
        provider: String,
        amount: Decimal,
        currency: String,
        cycle: SubscriptionCycle,
        nextRenewal: Date,
        notes: String? = nil,
        reminderDaysBefore: Int = 3,
        active: Bool = true
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.amount = amount
        self.currency = currency
        self.cycleRaw = cycle.rawValue
        self.nextRenewal = nextRenewal
        self.notes = notes
        self.reminderDaysBefore = reminderDaysBefore
        self.active = active
    }

    /// 按币种分组求和（§5.4 多币种不能跨币种 SUM）。
    public static func sumByCurrency(
        _ subscriptions: [Subscription],
        includeInactive: Bool = false
    ) -> [String: Decimal] {
        var result: [String: Decimal] = [:]
        for s in subscriptions where includeInactive || s.active {
            result[s.currency, default: 0] += s.amount
        }
        return result
    }
}
