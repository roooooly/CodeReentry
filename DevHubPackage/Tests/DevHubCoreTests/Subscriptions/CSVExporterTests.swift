import Foundation
import Testing
@testable import DevHubCore

@Suite("Subscription CSV Exporter")
struct CSVExporterTests {
    @Test("导出 Wallos 基础列并正确转义")
    func exportsCompatibleColumnsAndEscapes() throws {
        let renewal = try #require(Calendar(identifier: .gregorian).date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0), year: 2026, month: 8, day: 9
        )))
        let snapshot = SubscriptionSnapshot(
            id: UUID(), name: "AI, Pro", provider: "Vendor \"Cloud\"", amount: 19.95,
            currency: "USD", cycle: .monthly, nextRenewal: renewal,
            reminderDaysBefore: 5, notes: "line 1\nline 2", active: true
        )

        let csv = SubscriptionCSVExporter.export([snapshot])

        #expect(csv.hasPrefix(SubscriptionCSVExporter.header + "\n"))
        #expect(csv.contains("\"AI, Pro\""))
        #expect(csv.contains("\"Vendor \"\"Cloud\"\"\""))
        #expect(csv.contains("2026-08-09"))
        let roundTrip = try SubscriptionCSVImporter.parse(csv)
        #expect(roundTrip.count == 1)
        #expect(roundTrip[0].name == "AI, Pro")
        #expect(roundTrip[0].amount == Decimal(string: "19.95"))
        #expect(roundTrip[0].active)
    }

    @Test("空列表仍输出可导入表头")
    func exportsHeaderForEmptyList() throws {
        let csv = SubscriptionCSVExporter.export([])
        #expect(csv == SubscriptionCSVExporter.header + "\n")
        #expect(try SubscriptionCSVImporter.parse(csv).isEmpty)
    }
}
