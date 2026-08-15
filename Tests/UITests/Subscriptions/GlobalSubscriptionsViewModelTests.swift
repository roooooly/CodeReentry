import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("GlobalSubscriptionsViewModel")
@MainActor
struct GlobalSubscriptionsViewModelTests {
    private func makeStore() throws -> (SubscriptionStore, ModelContainer, Project) {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let project = Project(stableId: "project", name: "Project", path: "/tmp/project")
        container.mainContext.insert(project)
        try container.mainContext.save()
        return (SubscriptionStore(modelContainer: container), container, project)
    }

    @Test("全局新增保持 project=nil，汇总按币种归一")
    func createsGlobalSubscription() async throws {
        let (store, _, _) = try makeStore()
        let viewModel = GlobalSubscriptionsViewModel(store: store)

        _ = try await viewModel.create(SubscriptionInput(
            name: "Global", provider: "Vendor", amount: 120, currency: "USD",
            cycle: .yearly, nextRenewal: Date()
        ))

        #expect(viewModel.subscriptions.count == 1)
        #expect(viewModel.subscriptions.first?.projectId == nil)
        #expect(viewModel.monthlyByCurrency["USD"] == 10)
    }

    @Test("全局编辑项目订阅不会丢失原项目归属")
    func editingPreservesProject() async throws {
        let (store, _, project) = try makeStore()
        _ = try await store.create(SubscriptionInput(
            name: "Old", provider: "Vendor", amount: 5, currency: "CNY",
            cycle: .monthly, nextRenewal: Date(), projectId: project.id
        ))
        let viewModel = GlobalSubscriptionsViewModel(store: store)
        await viewModel.load()
        let original = try #require(viewModel.subscriptions.first)

        try await viewModel.update(original, with: SubscriptionInput(
            name: "New", provider: "Vendor", amount: 8, currency: "CNY",
            cycle: .monthly, nextRenewal: Date()
        ))

        #expect(viewModel.subscriptions.first?.name == "New")
        #expect(viewModel.subscriptions.first?.projectId == project.id)
    }

    @Test("提醒创建失败时订阅仍成功保存，且给出准确警告")
    func reminderFailureDoesNotMasqueradeAsSaveFailure() async throws {
        let (store, _, _) = try makeStore()
        let scheduler = ReminderScheduler(center: MockNotificationCenter(failOnAdd: true))
        let viewModel = GlobalSubscriptionsViewModel(store: store, reminderScheduler: scheduler)

        _ = try await viewModel.create(SubscriptionInput(
            name: "Saved", provider: "Vendor", amount: 20, currency: "CNY",
            cycle: .monthly, nextRenewal: Date()
        ))

        #expect(viewModel.subscriptions.count == 1)
        #expect(viewModel.subscriptions.first?.name == "Saved")
        let expectedPrefix = String(localized: "订阅已保存，但续费提醒创建失败：")
        #expect(viewModel.operationMessage?.hasPrefix(expectedPrefix) == true)
        #expect(viewModel.operationMessage?.contains(MockNotificationError.addFailed.localizedDescription) == true)
    }

    @Test("续费日历按月份分组且忽略停用订阅")
    func groupsRenewalsByMonth() async throws {
        let (store, _, _) = try makeStore()
        let calendar = Calendar(identifier: .gregorian)
        let july = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))
        let august = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1)))
        _ = try await store.create(SubscriptionInput(
            name: "July", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
            nextRenewal: july
        ))
        _ = try await store.create(SubscriptionInput(
            name: "August", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
            nextRenewal: august
        ))
        _ = try await store.create(SubscriptionInput(
            name: "Inactive", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
            nextRenewal: august, active: false
        ))
        let viewModel = GlobalSubscriptionsViewModel(store: store)
        await viewModel.load()

        #expect(viewModel.renewalMonths.count == 2)
        #expect(viewModel.renewalMonths.flatMap(\.subscriptions).map(\.name) == ["July", "August"])
    }
}
