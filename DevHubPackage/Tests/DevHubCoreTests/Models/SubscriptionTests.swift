import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("Subscription model")
struct SubscriptionTests {

    @Test("init sets defaults")
    func initDefaults() {
        let s = Subscription(
            name: "ChatGPT Pro",
            provider: "OpenAI",
            amount: 20,
            currency: "USD",
            cycle: .monthly,
            nextRenewal: Date(timeIntervalSinceNow: 86400 * 10)
        )
        #expect(s.reminderDaysBefore == 3)
        #expect(s.active == true)
        #expect(s.notes == nil)
    }

    @Test("Decimal survives SwiftData roundtrip")
    @MainActor
    func decimalRoundtrip() throws {
        let container = try ModelContainer(
            for: Subscription.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let s = Subscription(
            name: "GLM Code Plan",
            provider: "Z.ai",
            amount: Decimal(string: "99.90")!,
            currency: "CNY",
            cycle: .yearly,
            nextRenewal: Date()
        )
        ctx.insert(s)
        try ctx.save()
        let fetched = try ctx.fetch(FetchDescriptor<Subscription>()).first!
        #expect(fetched.amount == Decimal(string: "99.90"))
        #expect(fetched.currency == "CNY")
    }

    @Test("sumByCurrency groups and sums in memory")
    func sumByCurrency() {
        let subs: [Subscription] = [
            Subscription(name: "a", provider: "x", amount: 20, currency: "USD", cycle: .monthly, nextRenewal: Date()),
            Subscription(name: "b", provider: "x", amount: 5, currency: "USD", cycle: .monthly, nextRenewal: Date()),
            Subscription(name: "c", provider: "x", amount: 100, currency: "CNY", cycle: .monthly, nextRenewal: Date()),
            Subscription(name: "d", provider: "x", amount: 50, currency: "CNY", cycle: .monthly, nextRenewal: Date(), active: false),
        ]
        let sums = Subscription.sumByCurrency(subs, includeInactive: false)
        #expect(sums["USD"] == 25)
        #expect(sums["CNY"] == 100)
        #expect(sums.count == 2)
    }
}
