import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("SubscriptionStore")
struct SubscriptionStoreTests {

    @MainActor
    func makeStore() throws -> (SubscriptionStore, ModelContainer) {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Subscription.self, Project.self, Tool.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: config
        )
        let store = SubscriptionStore(modelContainer: container)
        return (store, container)
    }

    @MainActor
    @Test("create 写入并返回非零 id")
    func create() async throws {
        let (store, _) = try makeStore()
        let id = try await store.create(SubscriptionInput(
            name: "ChatGPT Pro", provider: "OpenAI",
            amount: 20, currency: "USD", cycle: .monthly,
            nextRenewal: Date(timeIntervalSinceNow: 86400 * 10)
        ))
        #expect(id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)))
    }

    @MainActor
    @Test("listSnapshots activeOnly=true 只返回 active")
    func listActive() async throws {
        let (store, _) = try makeStore()
        _ = try await store.create(SubscriptionInput(
            name: "A", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
            nextRenewal: Date()
        ))
        let list = try await store.listSnapshots(activeOnly: true)
        #expect(list.count == 1)
        #expect(list.first?.name == "A")
    }

    @MainActor
    @Test("update 修改 amount")
    func update() async throws {
        let (store, _) = try makeStore()
        let id = try await store.create(SubscriptionInput(
            name: "A", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
            nextRenewal: Date()
        ))
        try await store.update(id, amount: 99)
        let list = try await store.listSnapshots(activeOnly: false)
        #expect(list.first(where: { $0.amount == 99 }) != nil)
    }

    @MainActor
    @Test("delete 软删除：active=false，仍可被 activeOnly=false 列出")
    func softDelete() async throws {
        let (store, _) = try makeStore()
        let id = try await store.create(SubscriptionInput(
            name: "A", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
            nextRenewal: Date()
        ))
        try await store.delete(id)
        let active = try await store.listSnapshots(activeOnly: true)
        #expect(active.isEmpty)
        let all = try await store.listSnapshots(activeOnly: false)
        #expect(all.count == 1)
    }

    @MainActor
    @Test("create 关联 project（按 id）")
    func createWithProject() async throws {
        let (store, container) = try makeStore()
        let ctx = container.mainContext
        let project = Project(stableId: "s", name: "ExampleApp", path: "/tmp/ExampleApp")
        ctx.insert(project)
        try ctx.save()

        _ = try await store.create(SubscriptionInput(
            name: "A", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
            nextRenewal: Date(), projectId: project.id
        ))
        let list = try await store.listSnapshots(activeOnly: true, projectId: project.id)
        #expect(list.count == 1)
        #expect(list.first?.projectId == project.id)
    }

    @MainActor
    @Test("listSnapshots 按 projectId 隔离项目订阅")
    func listByProject() async throws {
        let (store, container) = try makeStore()
        let ctx = container.mainContext
        let first = Project(stableId: "first", name: "First", path: "/tmp/first")
        let second = Project(stableId: "second", name: "Second", path: "/tmp/second")
        ctx.insert(first)
        ctx.insert(second)
        try ctx.save()

        _ = try await store.create(SubscriptionInput(
            name: "First only", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
            nextRenewal: Date(), projectId: first.id
        ))
        _ = try await store.create(SubscriptionInput(
            name: "Second only", provider: "P", amount: 2, currency: "USD", cycle: .monthly,
            nextRenewal: Date(), projectId: second.id
        ))
        _ = try await store.create(SubscriptionInput(
            name: "Unscoped", provider: "P", amount: 3, currency: "USD", cycle: .monthly,
            nextRenewal: Date()
        ))

        let firstList = try await store.listSnapshots(activeOnly: false, projectId: first.id)
        let secondList = try await store.listSnapshots(activeOnly: false, projectId: second.id)
        #expect(firstList.map(\.name) == ["First only"])
        #expect(secondList.map(\.name) == ["Second only"])
        #expect(try await store.listSnapshots(activeOnly: false).count == 3)
    }

    @MainActor
    @Test("create 指定不存在项目时拒绝写入")
    func createRejectsMissingProject() async throws {
        let (store, _) = try makeStore()
        let missingId = UUID()
        await #expect(throws: SubscriptionStoreError.projectNotFound(missingId)) {
            try await store.create(SubscriptionInput(
                name: "A", provider: "P", amount: 1, currency: "USD", cycle: .monthly,
                nextRenewal: Date(), projectId: missingId
            ))
        }
        #expect(try await store.listSnapshots(activeOnly: false).isEmpty)
    }

    @MainActor
    @Test("完整 update 更新字段并保留项目关联")
    func fullUpdate() async throws {
        let (store, container) = try makeStore()
        let ctx = container.mainContext
        let project = Project(stableId: "p", name: "P", path: "/tmp/p")
        ctx.insert(project)
        try ctx.save()
        let id = try await store.create(SubscriptionInput(
            name: "Old", provider: "Old P", amount: 1, currency: "USD", cycle: .monthly,
            nextRenewal: Date(timeIntervalSince1970: 1), projectId: project.id
        ))

        let renewal = Date(timeIntervalSince1970: 2_000_000)
        try await store.update(id, with: SubscriptionInput(
            name: "New", provider: "New P", amount: 120, currency: "CNY", cycle: .yearly,
            nextRenewal: renewal, reminderDaysBefore: 7, notes: "team plan",
            projectId: project.id, active: false
        ))

        let updated = try #require(
            try await store.listSnapshots(activeOnly: false, projectId: project.id).first
        )
        #expect(updated.name == "New")
        #expect(updated.provider == "New P")
        #expect(updated.amount == 120)
        #expect(updated.currency == "CNY")
        #expect(updated.cycle == .yearly)
        #expect(updated.nextRenewal == renewal)
        #expect(updated.reminderDaysBefore == 7)
        #expect(updated.notes == "team plan")
        #expect(updated.projectId == project.id)
        #expect(updated.active == false)
    }
}
