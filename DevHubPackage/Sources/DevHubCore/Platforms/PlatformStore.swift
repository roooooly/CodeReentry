import Foundation
import SwiftData

public enum PlatformStoreError: Error, Equatable {
    case duplicateBinding
    case notFound
    case invalidDisplayName
    case invalidLoginURL
}

extension PlatformStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateBinding:
            return String(localized: "该账号已经绑定到当前项目。")
        case .notFound:
            return String(localized: "要操作的平台账号或绑定已不存在，请刷新后重试。")
        case .invalidDisplayName:
            return String(localized: "账号显示名不能为空。")
        case .invalidLoginURL:
            return String(localized: "登录地址必须是包含协议的有效 URL。")
        }
    }
}

/// 绑定编辑的完整输入。使用值类型避免用多个 Optional 区分“保持不变”和“清空字段”。
public struct PlatformBindingUpdate: Sendable, Equatable {
    public var publishStatus: PublishStatus
    public var publishUrl: String?
    public var publishNotes: String?
    public var lastPublishedAt: Date?

    public init(
        publishStatus: PublishStatus,
        publishUrl: String?,
        publishNotes: String?,
        lastPublishedAt: Date?
    ) {
        self.publishStatus = publishStatus
        self.publishUrl = publishUrl
        self.publishNotes = publishNotes
        self.lastPublishedAt = lastPublishedAt
    }
}

/// 平台账号 + 项目×账号绑定的 CRUD（§5.5）。@ModelActor 隔离 SwiftData 操作。
@ModelActor
public actor PlatformStore {

    // MARK: - Account

    @discardableResult
    public func createAccount(platform: Platform, displayName: String, loginUrl: String) async throws -> PlatformAccountSnapshot {
        let input = try normalizedAccountInput(displayName: displayName, loginUrl: loginUrl)
        let acc = PlatformAccount(platform: platform, displayName: input.displayName, loginUrl: input.loginURL)
        modelContext.insert(acc)
        try modelContext.save()
        return PlatformAccountSnapshot(acc)
    }

    public func allAccounts() async throws -> [PlatformAccountSnapshot] {
        try modelContext.fetch(FetchDescriptor<PlatformAccount>(sortBy: [.init(\.displayName)])).map(PlatformAccountSnapshot.init)
    }

    public func accounts(platform: Platform) async throws -> [PlatformAccountSnapshot] {
        // platform 是计算属性（基于 platformRaw），#Predicate 不能用计算属性——按 raw 查
        let raw = platform.rawValue
        return try modelContext.fetch(FetchDescriptor<PlatformAccount>(
            predicate: #Predicate { $0.platformRaw == raw }
        )).map(PlatformAccountSnapshot.init)
    }

    public func account(id: UUID) async throws -> PlatformAccountSnapshot? {
        let i = id
        return try modelContext.fetch(FetchDescriptor<PlatformAccount>(
            predicate: #Predicate { $0.id == i }
        )).first.map(PlatformAccountSnapshot.init)
    }

    public func updateAccount(id: UUID, displayName: String, loginUrl: String) async throws {
        let i = id
        guard let acc = try modelContext.fetch(FetchDescriptor<PlatformAccount>(
            predicate: #Predicate { $0.id == i }
        )).first else { throw PlatformStoreError.notFound }
        try updateAccount(acc, platform: acc.platform, displayName: displayName, loginUrl: loginUrl)
    }

    /// 完整账号更新；平台也可修改，供账号编辑表单使用。
    public func updateAccount(
        id: UUID,
        platform: Platform,
        displayName: String,
        loginUrl: String
    ) async throws {
        let i = id
        guard let acc = try modelContext.fetch(FetchDescriptor<PlatformAccount>(
            predicate: #Predicate { $0.id == i }
        )).first else { throw PlatformStoreError.notFound }
        try updateAccount(acc, platform: platform, displayName: displayName, loginUrl: loginUrl)
    }

    public func deleteAccount(id: UUID) async throws {
        let i = id
        guard let acc = try modelContext.fetch(FetchDescriptor<PlatformAccount>(
            predicate: #Predicate { $0.id == i }
        )).first else { throw PlatformStoreError.notFound }

        // PlatformAccount 没有反向 relationship；显式删除绑定，避免留下 account=nil 的孤儿记录。
        let bindings = try modelContext.fetch(FetchDescriptor<ProjectPlatformBinding>(
            predicate: #Predicate { $0.account?.id == i }
        ))
        for binding in bindings {
            modelContext.delete(binding)
        }
        modelContext.delete(acc)
        try modelContext.save()
    }

    private func updateAccount(
        _ account: PlatformAccount,
        platform: Platform,
        displayName: String,
        loginUrl: String
    ) throws {
        let input = try normalizedAccountInput(displayName: displayName, loginUrl: loginUrl)
        account.platform = platform
        account.displayName = input.displayName
        account.loginUrl = input.loginURL
        try modelContext.save()
    }

    private func normalizedAccountInput(
        displayName: String,
        loginUrl: String
    ) throws -> (displayName: String, loginURL: String) {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw PlatformStoreError.invalidDisplayName }

        let loginURL = loginUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: loginURL), url.scheme?.isEmpty == false else {
            throw PlatformStoreError.invalidLoginURL
        }
        return (name, loginURL)
    }

    // MARK: - Binding

    @discardableResult
    public func bind(projectId: UUID, accountId: UUID, status: PublishStatus) async throws -> PlatformBindingSnapshot {
        let pid = projectId; let aid = accountId
        let dup = try modelContext.fetch(FetchDescriptor<ProjectPlatformBinding>(
            predicate: #Predicate { $0.project?.id == pid && $0.account?.id == aid }
        ))
        if !dup.isEmpty { throw PlatformStoreError.duplicateBinding }

        guard let project = try modelContext.fetch(FetchDescriptor<Project>(
            predicate: #Predicate { $0.id == pid }
        )).first,
        let account = try modelContext.fetch(FetchDescriptor<PlatformAccount>(
            predicate: #Predicate { $0.id == aid }
        )).first else {
            throw PlatformStoreError.notFound
        }
        let b = ProjectPlatformBinding(project: project, account: account,
                                       publishStatus: status, publishUrl: nil,
                                       publishNotes: nil,
                                       lastPublishedAt: status == .published ? Date() : nil)
        modelContext.insert(b)
        try modelContext.save()
        return PlatformBindingSnapshot(b)
    }

    public func bindings(projectId: UUID) async throws -> [PlatformBindingSnapshot] {
        let pid = projectId
        return try modelContext.fetch(FetchDescriptor<ProjectPlatformBinding>(
            predicate: #Predicate { $0.project?.id == pid },
            sortBy: [.init(\.publishStatusRaw)]
        )).map(PlatformBindingSnapshot.init)
    }

    public func binding(id: UUID) async throws -> PlatformBindingSnapshot? {
        let i = id
        return try modelContext.fetch(FetchDescriptor<ProjectPlatformBinding>(
            predicate: #Predicate { $0.id == i }
        )).first.map(PlatformBindingSnapshot.init)
    }

    public func updateBinding(id: UUID, status: PublishStatus?,
                              publishUrl: String?, notes: String?) async throws {
        let i = id
        guard let b = try modelContext.fetch(FetchDescriptor<ProjectPlatformBinding>(
            predicate: #Predicate { $0.id == i }
        )).first else { throw PlatformStoreError.notFound }
        let nextStatus = status ?? b.publishStatus
        try applyBindingUpdate(
            PlatformBindingUpdate(
                publishStatus: nextStatus,
                publishUrl: publishUrl,
                publishNotes: notes,
                lastPublishedAt: nextStatus == .published ? (b.lastPublishedAt ?? Date()) : b.lastPublishedAt
            ),
            to: b
        )
    }

    /// 完整绑定更新，包含可显式设置或清空的最后发布时间。
    public func updateBinding(id: UUID, update: PlatformBindingUpdate) async throws {
        let i = id
        guard let binding = try modelContext.fetch(FetchDescriptor<ProjectPlatformBinding>(
            predicate: #Predicate { $0.id == i }
        )).first else { throw PlatformStoreError.notFound }
        try applyBindingUpdate(update, to: binding)
    }

    private func applyBindingUpdate(
        _ update: PlatformBindingUpdate,
        to binding: ProjectPlatformBinding
    ) throws {
        binding.publishStatus = update.publishStatus
        binding.publishUrl = normalizedOptionalText(update.publishUrl)
        binding.publishNotes = normalizedOptionalText(update.publishNotes)
        binding.lastPublishedAt = update.lastPublishedAt
        try modelContext.save()
    }

    private func normalizedOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func deleteBinding(id: UUID) async throws {
        let i = id
        guard let b = try modelContext.fetch(FetchDescriptor<ProjectPlatformBinding>(
            predicate: #Predicate { $0.id == i }
        )).first else { throw PlatformStoreError.notFound }
        modelContext.delete(b)
        try modelContext.save()
    }
}
