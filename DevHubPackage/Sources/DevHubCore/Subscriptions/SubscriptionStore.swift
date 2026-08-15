import Foundation
import SwiftData

public enum SubscriptionStoreError: LocalizedError, Sendable, Equatable {
    case projectNotFound(UUID)
    case subscriptionNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return String(localized: "找不到要关联的项目。")
        case .subscriptionNotFound:
            return String(localized: "找不到要更新的订阅。")
        }
    }
}

/// 订阅创建/更新的输入 DTO（不依赖 SwiftData @Model，便于测试 + 跨 actor 传递）。
public struct SubscriptionInput: Sendable, Equatable {
    public var name: String
    public var provider: String
    public var amount: Decimal
    public var currency: String
    public var cycle: SubscriptionCycle
    public var nextRenewal: Date
    public var reminderDaysBefore: Int
    public var notes: String?
    public var projectId: UUID?
    public var active: Bool

    public init(name: String, provider: String, amount: Decimal, currency: String,
                cycle: SubscriptionCycle, nextRenewal: Date,
                reminderDaysBefore: Int = 3, notes: String? = nil,
                projectId: UUID? = nil, active: Bool = true) {
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
}

/// 订阅 CRUD（§5.4）。@ModelActor 把 SwiftData 操作隔离到容器自己的 executor。
/// delete 为软删除（active=false，保留历史账目）。
@ModelActor
public actor SubscriptionStore {

    @discardableResult
    public func create(_ input: SubscriptionInput) async throws -> UUID {
        let project: Project?
        if let projectId = input.projectId {
            let desc = FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectId })
            guard let found = try modelContext.fetch(desc).first else {
                throw SubscriptionStoreError.projectNotFound(projectId)
            }
            project = found
        } else {
            project = nil
        }

        let sub = Subscription(
            name: input.name,
            provider: input.provider,
            amount: input.amount,
            currency: input.currency,
            cycle: input.cycle,
            nextRenewal: input.nextRenewal,
            notes: input.notes,
            reminderDaysBefore: input.reminderDaysBefore,
            active: input.active
        )
        sub.project = project
        modelContext.insert(sub)
        try modelContext.save()
        return sub.id
    }

    /// 取回订阅。activeOnly=true 只返回 active。返回的是 detached snapshot（Sendable），
    /// 避免把非 Sendable 的 @Model 跨 actor 传出去。
    public func listSnapshots(
        activeOnly: Bool,
        projectId: UUID? = nil
    ) async throws -> [SubscriptionSnapshot] {
        let desc = FetchDescriptor<Subscription>(
            predicate: activeOnly ? #Predicate { $0.active == true } : nil,
            sortBy: [SortDescriptor(\.nextRenewal)]
        )
        var subs = try modelContext.fetch(desc)
        if let projectId {
            subs = subs.filter { $0.project?.id == projectId }
        }
        return subs.map(SubscriptionSnapshot.init)
    }

    /// 用完整输入替换可编辑字段。项目关联也随输入更新，避免项目页编辑后丢失作用域。
    public func update(_ id: UUID, with input: SubscriptionInput) async throws {
        let desc = FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == id })
        guard let sub = try modelContext.fetch(desc).first else {
            throw SubscriptionStoreError.subscriptionNotFound(id)
        }

        let project: Project?
        if let projectId = input.projectId {
            let projectDesc = FetchDescriptor<Project>(predicate: #Predicate { $0.id == projectId })
            guard let found = try modelContext.fetch(projectDesc).first else {
                throw SubscriptionStoreError.projectNotFound(projectId)
            }
            project = found
        } else {
            project = nil
        }

        sub.name = input.name
        sub.provider = input.provider
        sub.amount = input.amount
        sub.currency = input.currency
        sub.cycle = input.cycle
        sub.nextRenewal = input.nextRenewal
        sub.reminderDaysBefore = input.reminderDaysBefore
        sub.notes = input.notes
        sub.active = input.active
        sub.project = project
        try modelContext.save()
    }

    public func update(_ id: UUID, amount: Decimal? = nil, nextRenewal: Date? = nil,
                       notes: String? = nil, active: Bool? = nil) async throws {
        let desc = FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == id })
        guard let sub = try modelContext.fetch(desc).first else { return }
        if let amount { sub.amount = amount }
        if let nextRenewal { sub.nextRenewal = nextRenewal }
        if let notes { sub.notes = notes }
        if let active { sub.active = active }
        try modelContext.save()
    }

    /// 软删除：active=false，保留历史账目（§5.4 历史回顾）。
    public func delete(_ id: UUID) async throws {
        try await update(id, active: false)
    }

    /// 批量导入 CSV 行（§5.4 Wallos 兼容）。
    /// `onScheduled` 可选回调：app 层用它接 ReminderScheduler（Core 不依赖 UserNotifications）。
    public func importRows(
        _ rows: [ImportedSubscriptionRow],
        projectId: UUID? = nil,
        onScheduled: (@Sendable (UUID, String, Date) async throws -> Void)? = nil
    ) async throws {
        for row in rows {
            let input = SubscriptionInput(
                name: row.name, provider: row.name,  // CSV 无 provider 列，复用 name
                amount: row.amount, currency: row.currency, cycle: row.cycle,
                nextRenewal: row.nextRenewal, reminderDaysBefore: 3,
                notes: nil, projectId: projectId, active: row.active
            )
            let id = try await create(input)
            if row.active, let onScheduled {
                try await onScheduled(id, row.name, row.nextRenewal)
            }
        }
    }
}
