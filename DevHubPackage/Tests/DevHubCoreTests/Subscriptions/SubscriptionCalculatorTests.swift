import Testing
import Foundation
@testable import DevHubCore

@Suite("SubscriptionCalculator")
struct SubscriptionCalculatorTests {

    func sub(_ amount: Decimal, _ currency: String, _ cycle: SubscriptionCycle = .monthly, active: Bool = true) -> SubscriptionSnapshot {
        SubscriptionSnapshot(id: UUID(), name: "x", provider: "p", amount: amount,
                             currency: currency, cycle: cycle, nextRenewal: Date(),
                             reminderDaysBefore: 3, active: active)
    }

    @Test("按币种分组 SUM，不跨币种")
    func groupByCurrency() {
        let snap = [sub(10, "USD"), sub(20, "USD"), sub(100, "CNY"), sub(50, "CNY")]
        let result = SubscriptionCalculator.monthlyTotalsByCurrency(snap)
        #expect(result["USD"] == 30)
        #expect(result["CNY"] == 150)
    }

    @Test("yearly 金额按月度归一（除以 12）")
    func normalizeYearly() {
        let snap = [sub(120, "USD", .yearly)]  // 年付 120 → 月均 10
        let result = SubscriptionCalculator.monthlyTotalsByCurrency(snap)
        #expect(result["USD"] == 10)
    }

    @Test("inactive 不计入")
    func skipInactive() {
        let snap = [
            sub(10, "USD", active: true),
            sub(100, "USD", active: false)
        ]
        let result = SubscriptionCalculator.monthlyTotalsByCurrency(snap)
        #expect(result["USD"] == 10)
    }

    @Test("yearlyTotals 等于 monthly × 12")
    func yearlyMatches() {
        let snap = [sub(10, "USD")]
        let monthly = SubscriptionCalculator.monthlyTotalsByCurrency(snap)
        let yearly = SubscriptionCalculator.yearlyTotalsByCurrency(snap)
        #expect(yearly["USD"] == monthly["USD"]! * 12)
    }

    @Test("referenceRate 换算到展示币种")
    func convertToDisplay() {
        let snap = [sub(10, "USD"), sub(100, "CNY")]
        let rate: [String: Decimal] = ["USD": 7.2]  // 1 USD = 7.2 CNY
        let display = SubscriptionCalculator.monthlyTotalInDisplayCurrency(
            snap, displayCurrency: "CNY", referenceRates: rate
        )
        // 10 USD * 7.2 + 100 CNY = 172
        #expect(display == Decimal(string: "172"))
    }

    @Test("无汇率的币种被跳过（不隐式换算）")
    func noImplicitConversion() {
        let snap = [sub(10, "USD"), sub(5, "EUR")]
        let display = SubscriptionCalculator.monthlyTotalInDisplayCurrency(
            snap, displayCurrency: "CNY", referenceRates: ["USD": 7.2]  // 无 EUR 汇率
        )
        // 仅 USD 10 * 7.2 = 72，EUR 被跳过
        #expect(display == Decimal(string: "72"))
    }

    @Test("monthlyAmount/yearlyAmount 互逆")
    func cycleRoundTrip() {
        #expect(SubscriptionCycle.monthly.monthlyAmount(100) == 100)
        #expect(SubscriptionCycle.monthly.yearlyAmount(100) == 1200)
        #expect(SubscriptionCycle.yearly.monthlyAmount(1200) == 100)
        #expect(SubscriptionCycle.yearly.yearlyAmount(1200) == 1200)
    }
}
