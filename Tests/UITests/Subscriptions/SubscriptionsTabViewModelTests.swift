import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("SubscriptionsTabViewModel")
@MainActor
struct SubscriptionsTabViewModelTests {

    func makeStore() throws -> (SubscriptionStore, ModelContainer, UUID) {
        let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Subscription.self, Project.self, Tool.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: cfg
        )
        let project = Project(stableId: UUID().uuidString, name: "Test", path: "/tmp/test")
        container.mainContext.insert(project)
        try container.mainContext.save()
        return (SubscriptionStore(modelContainer: container), container, project.id)
    }

    @Test("load 拉取订阅并生成币种分组")
    func loadGroupsByCurrency() async throws {
        let (store, _, projectId) = try makeStore()
        _ = try await store.create(SubscriptionInput(
            name: "A", provider: "P", amount: 10, currency: "USD", cycle: .monthly,
            nextRenewal: Date(), projectId: projectId
        ))
        _ = try await store.create(SubscriptionInput(
            name: "B", provider: "P", amount: 100, currency: "CNY", cycle: .monthly,
            nextRenewal: Date(), projectId: projectId
        ))

        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store)
        await vm.load()
        #expect(vm.monthlyByCurrency["USD"] == 10)
        #expect(vm.monthlyByCurrency["CNY"] == 100)
        #expect(vm.subscriptions.count == 2)
    }

    @Test("load yearly 归一（120/年 → 10/月）")
    func loadYearlyNormalized() async throws {
        let (store, _, projectId) = try makeStore()
        _ = try await store.create(SubscriptionInput(
            name: "GLM", provider: "Z", amount: 120, currency: "USD", cycle: .yearly,
            nextRenewal: Date(), projectId: projectId
        ))
        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store)
        await vm.load()
        #expect(vm.monthlyByCurrency["USD"] == 10)   // 120/12
        #expect(vm.yearlyByCurrency["USD"] == 120)
    }

    @Test("停用后保留历史且不计入汇总，随后可恢复")
    func disableAndRestore() async throws {
        let (store, _, projectId) = try makeStore()
        _ = try await store.create(SubscriptionInput(
            name: "A", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
            nextRenewal: Date(), projectId: projectId
        ))
        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store)
        await vm.load()
        #expect(vm.subscriptions.count == 1)
        let subscription = try #require(vm.subscriptions.first)

        await vm.setActive(subscription, active: false)
        #expect(vm.subscriptions.count == 1)
        #expect(vm.subscriptions.first?.active == false)
        #expect(vm.monthlyByCurrency.isEmpty)

        let inactive = try #require(vm.subscriptions.first)
        await vm.setActive(inactive, active: true)
        #expect(vm.subscriptions.first?.active == true)
        #expect(vm.monthlyByCurrency["USD"] == 1)
    }

    @Test("create 写入并触发 load 刷新")
    func createRefreshes() async throws {
        let (store, _, projectId) = try makeStore()
        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store)
        await vm.load()
        #expect(vm.subscriptions.isEmpty)
        _ = try await vm.create(SubscriptionInput(
            name: "New", provider: "P", amount: 5, currency: "USD", cycle: .monthly, nextRenewal: Date()
        ))
        #expect(vm.subscriptions.count == 1)
        #expect(vm.monthlyByCurrency["USD"] == 5)
        #expect(vm.subscriptions.first?.projectId == projectId)
    }

    @Test("软删除订阅后刷新历史列表与汇总")
    func deleteRefreshes() async throws {
        let (store, _, projectId) = try makeStore()
        let id = try await store.create(SubscriptionInput(
            name: "Delete Me", provider: "P", amount: 12, currency: "USD", cycle: .monthly,
            nextRenewal: Date(), projectId: projectId
        ))
        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store)
        await vm.load()
        #expect(vm.subscriptions.count == 1)

        await vm.delete(id)

        #expect(vm.subscriptions.count == 1)
        #expect(vm.subscriptions.first?.active == false)
        #expect(vm.monthlyByCurrency.isEmpty)
        #expect(vm.yearlyByCurrency.isEmpty)
        #expect(vm.operationError == nil)
    }

    @Test("create 触发 reminderScheduler.schedule")
    func createSchedulesReminder() async throws {
        let (store, _, projectId) = try makeStore()
        let center = MockNotificationCenter()
        let scheduler = ReminderScheduler(center: center)
        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store, reminderScheduler: scheduler)
        _ = try await vm.create(SubscriptionInput(
            name: "X", provider: "P", amount: 1, currency: "USD", cycle: .monthly, nextRenewal: Date()
        ))
        #expect(center.addedRequests.count == 1)
    }

    @Test("importCSV 导入 Wallos 格式 → 提示成功 + load 列表更新")
    func importCSVPopulates() async throws {
        let (store, _, projectId) = try makeStore()
        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store, reminderScheduler: nil)
        // Wallos 兼容 CSV（标准列）
        let csv = """
        Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active
        Netflix,15.99,USD,1,monthly,2026-08-01,1
        Jetbrains,240,USD,1,yearly,2026-12-01,1
        """
        await vm.importCSV(csv)
        #expect(vm.csvImportResult?.contains("2") == true)
        await vm.load()
        #expect(vm.subscriptions.count == 2)
        #expect(vm.subscriptions.contains { $0.name == "Netflix" })
        #expect(vm.subscriptions.contains { $0.name == "Jetbrains" })
        #expect(vm.subscriptions.allSatisfy { $0.projectId == projectId })
    }

    @Test("importCSV 空内容 → 提示无可识别行")
    func importCSVEmpty() async throws {
        let (store, _, projectId) = try makeStore()
        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store, reminderScheduler: nil)
        await vm.importCSV("Name,Price\n")
        #expect(vm.csvImportResult?.contains("没有") == true)
        #expect(vm.subscriptions.isEmpty)
    }

    @Test("importCSV 列名不匹配 → 解析返回空行 → 提示无可识别行")
    func importCSVMalformed() async throws {
        let (store, _, projectId) = try makeStore()
        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store, reminderScheduler: nil)
        // 无标准列名，解析器跳过所有行 → 空
        await vm.importCSV("这根本不是CSV\n也还是不行")
        #expect(vm.csvImportResult?.contains("没有") == true)
        #expect(vm.subscriptions.isEmpty)
    }

    @Test("load 只显示当前项目的订阅")
    func loadIsProjectScoped() async throws {
        let (store, container, projectId) = try makeStore()
        let otherProject = Project(stableId: "other", name: "Other", path: "/tmp/other")
        container.mainContext.insert(otherProject)
        try container.mainContext.save()
        _ = try await store.create(SubscriptionInput(
            name: "Current", provider: "P", amount: 10, currency: "USD", cycle: .monthly,
            nextRenewal: Date(), projectId: projectId
        ))
        _ = try await store.create(SubscriptionInput(
            name: "Other", provider: "P", amount: 99, currency: "USD", cycle: .monthly,
            nextRenewal: Date(), projectId: otherProject.id
        ))

        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store)
        await vm.load()

        #expect(vm.subscriptions.map(\.name) == ["Current"])
        #expect(vm.monthlyByCurrency["USD"] == 10)
    }

    @Test("update 编辑完整字段并刷新月度和年度汇总")
    func updateRefreshesFieldsAndTotals() async throws {
        let (store, _, projectId) = try makeStore()
        let id = try await store.create(SubscriptionInput(
            name: "Old", provider: "P", amount: 10, currency: "USD", cycle: .monthly,
            nextRenewal: Date(), projectId: projectId
        ))
        let vm = SubscriptionsTabViewModel(projectId: projectId, store: store)
        await vm.load()

        try await vm.update(id, with: SubscriptionInput(
            name: "New", provider: "Provider", amount: 240, currency: "CNY", cycle: .yearly,
            nextRenewal: Date(timeIntervalSince1970: 2_000_000), reminderDaysBefore: 10,
            notes: "note"
        ))

        let updated = try #require(vm.subscriptions.first)
        #expect(updated.name == "New")
        #expect(updated.provider == "Provider")
        #expect(updated.notes == "note")
        #expect(updated.projectId == projectId)
        #expect(vm.monthlyByCurrency["CNY"] == 20)
        #expect(vm.yearlyByCurrency["CNY"] == 240)
    }

    @Test("create 失败会生成可展示错误")
    func createFailureIsVisible() async throws {
        let (store, _, _) = try makeStore()
        let vm = SubscriptionsTabViewModel(projectId: UUID(), store: store)

        await #expect(throws: SubscriptionStoreError.self) {
            try await vm.create(SubscriptionInput(
                name: "A", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
                nextRenewal: Date()
            ))
        }
        #expect(vm.operationError?.contains("无法添加") == true)
    }
}
