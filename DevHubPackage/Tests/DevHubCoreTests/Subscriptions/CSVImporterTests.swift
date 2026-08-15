import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("SubscriptionCSVImporter")
struct SubscriptionCSVImporterTests {

    @Test("解析 Wallos 标准行")
    func parseWallos() throws {
        let csv = """
        Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active
        ChatGPT Pro,20,USD,1,Monthly,2026-08-18,1
        GLM,144,CNY,1,Yearly,2026-12-01,1
        """
        let rows = try SubscriptionCSVImporter.parse(csv)
        #expect(rows.count == 2)
        #expect(rows[0].name == "ChatGPT Pro")
        #expect(rows[0].amount == 20)
        #expect(rows[0].currency == "USD")
        #expect(rows[0].cycle == .monthly)
        #expect(rows[1].cycle == .yearly)
        #expect(rows[1].currency == "CNY")
    }

    @Test("Active=0 行标记 active=false")
    func inactiveRow() throws {
        let csv = "Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active\nOld,1,USD,1,Monthly,2026-08-18,0"
        let rows = try SubscriptionCSVImporter.parse(csv)
        #expect(rows[0].active == false)
    }

    @Test("日期格式兼容 YYYY-MM-DD")
    func dateFormat() throws {
        let csv = "Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active\nX,1,USD,1,Monthly,2026-08-18,1"
        let rows = try SubscriptionCSVImporter.parse(csv)
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents([.year, .month, .day], from: rows[0].nextRenewal)
        #expect(comps.year == 2026)
        #expect(comps.month == 8)
        #expect(comps.day == 18)
    }

    @Test("坏行跳过不抛")
    func skipsBadRows() throws {
        let csv = """
        Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active
        Good,1,USD,1,Monthly,2026-08-18,1
        Bad,abc,USD,1,Monthly,not-a-date,1
        """
        let rows = try SubscriptionCSVImporter.parse(csv)
        #expect(rows.count == 1)
        #expect(rows[0].name == "Good")
    }

    @Test("未知 Cycle_type 默认 monthly")
    func unknownCycle() throws {
        let csv = "Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active\nX,1,USD,1,Weekly,2026-08-18,1"
        let rows = try SubscriptionCSVImporter.parse(csv)
        #expect(rows[0].cycle == .monthly)
    }

    @Test("空 CSV 返回空数组")
    func empty() throws {
        #expect(try SubscriptionCSVImporter.parse("").isEmpty)
        #expect(try SubscriptionCSVImporter.parse("Name,Price\n").isEmpty)  // 只有 header
    }
}

@Suite("SubscriptionStore CSV bridge")
struct SubscriptionStoreCSVTests {

    /// Sendable 收集盒，用于跨 actor 闭包收集结果。
    final class Box<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [T] = []
        func append(_ x: T) { lock.withLock { items.append(x) } }
        var values: [T] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
    }

    @MainActor
    @Test("importRows 写入所有行 + 触发 onScheduled 回调")
    func importToStore() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Subscription.self, Project.self, Tool.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: config
        )
        let store = SubscriptionStore(modelContainer: container)
        let csv = "Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active\nA,1,USD,1,Monthly,2026-08-18,1\nB,2,CNY,1,Yearly,2026-12-01,1"
        let rows = try SubscriptionCSVImporter.parse(csv)

        let scheduled = Box<String>()
        try await store.importRows(rows, onScheduled: { _, name, _ in
            scheduled.append(name)
        })

        let list = try await store.listSnapshots(activeOnly: true)
        #expect(list.count == 2)
        #expect(scheduled.count == 2)
        #expect(scheduled.values.sorted() == ["A", "B"])
    }

    @MainActor
    @Test("importRows inactive 行不触发回调")
    func importInactiveNoSchedule() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Subscription.self, Project.self,
            configurations: config
        )
        let store = SubscriptionStore(modelContainer: container)
        let csv = "Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active\nA,1,USD,1,Monthly,2026-08-18,0"
        let rows = try SubscriptionCSVImporter.parse(csv)

        let scheduled = Box<String>()
        try await store.importRows(rows, onScheduled: { _, name, _ in
            scheduled.append(name)
        })
        #expect(scheduled.count == 0)
        let all = try await store.listSnapshots(activeOnly: false)
        #expect(all.count == 1)
        #expect(all.first?.active == false)
    }

    @MainActor
    @Test("importRows 把 CSV 行关联到指定项目")
    func importAssociatesProject() async throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Subscription.self, Project.self,
            configurations: config
        )
        let project = Project(stableId: "csv-project", name: "CSV", path: "/tmp/csv")
        container.mainContext.insert(project)
        try container.mainContext.save()
        let store = SubscriptionStore(modelContainer: container)
        let rows = try SubscriptionCSVImporter.parse(
            "Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active\nA,1,USD,1,Monthly,2026-08-18,1"
        )

        try await store.importRows(rows, projectId: project.id)

        let scoped = try await store.listSnapshots(activeOnly: false, projectId: project.id)
        #expect(scoped.count == 1)
        #expect(scoped.first?.name == "A")
        #expect(scoped.first?.projectId == project.id)
    }
}
