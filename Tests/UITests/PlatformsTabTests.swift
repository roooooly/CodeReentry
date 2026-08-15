import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("PlatformsTabViewModel")
@MainActor
struct PlatformsTabViewModelTests {
    struct Environment {
        let container: ModelContainer
        let store: PlatformStore
        let projectId: UUID
    }

    func makeEnvironment() throws -> Environment {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let project = Project(
            stableId: UUID().uuidString,
            name: "Platform Test",
            path: "/tmp/platform-test"
        )
        container.mainContext.insert(project)
        try container.mainContext.save()
        return Environment(
            container: container,
            store: PlatformStore(modelContainer: container),
            projectId: project.id
        )
    }

    @Test("新账号表单用平台 preset 初始化，切换平台更新未修改字段")
    func accountDraftUsesPresetDefaults() {
        var draft = PlatformAccountFormDraft(platform: .xiaohongshu)
        #expect(draft.displayName == "小红书")
        #expect(draft.loginUrl == "https://creator.xiaohongshu.com/")

        draft.applyPresetChange(from: .xiaohongshu, to: .twitter)
        #expect(draft.platform == .twitter)
        #expect(draft.displayName == "X (Twitter)")
        #expect(draft.loginUrl == "https://x.com/")

        draft.loginUrl = "https://x.com/custom"
        draft.applyPresetChange(from: .twitter, to: .wechatOA)
        #expect(draft.displayName == "微信公众号")
        #expect(draft.loginUrl == "https://x.com/custom")
    }

    @Test("账号 create/update/delete 完整刷新 ViewModel")
    func accountCRUDRefreshesViewModel() async throws {
        let environment = try makeEnvironment()
        let viewModel = PlatformsTabViewModel(
            store: environment.store,
            projectId: environment.projectId
        )

        await viewModel.load()
        #expect(viewModel.accounts.isEmpty)
        #expect(viewModel.loadError == nil)

        try await viewModel.addAccount(PlatformAccountFormDraft(platform: .twitter))
        let created = try #require(viewModel.accounts.first)
        #expect(created.displayName == "X (Twitter)")
        #expect(created.loginUrl == "https://x.com/")

        var edit = PlatformAccountFormDraft(account: created)
        edit.displayName = "工作账号"
        edit.loginUrl = "https://x.com/work"
        try await viewModel.updateAccount(id: created.id, draft: edit)
        #expect(viewModel.accounts.first?.displayName == "工作账号")
        #expect(viewModel.accounts.first?.loginUrl == "https://x.com/work")

        await viewModel.deleteAccount(id: created.id)
        #expect(viewModel.accounts.isEmpty)
        #expect(viewModel.saveError == nil)
    }

    @Test("绑定发布信息可完整更新并清空最后发布时间")
    func bindingUpdatePersistsEveryField() async throws {
        let environment = try makeEnvironment()
        let viewModel = PlatformsTabViewModel(
            store: environment.store,
            projectId: environment.projectId
        )
        try await viewModel.addAccount(PlatformAccountFormDraft(platform: .xiaohongshu))
        let account = try #require(viewModel.accounts.first)
        await viewModel.bind(accountId: account.id)
        let binding = try #require(viewModel.bindings.first)

        var draft = PlatformBindingFormDraft(binding: binding)
        let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)
        draft.publishStatus = .published
        draft.publishUrl = "https://creator.xiaohongshu.com/post/1"
        draft.publishNotes = "首发"
        draft.hasLastPublishedAt = true
        draft.lastPublishedAt = publishedAt
        try await viewModel.updateBinding(id: binding.id, draft: draft)

        var updated = try #require(viewModel.bindings.first)
        #expect(updated.publishStatus == .published)
        #expect(updated.publishUrl == "https://creator.xiaohongshu.com/post/1")
        #expect(updated.publishNotes == "首发")
        #expect(updated.lastPublishedAt == publishedAt)

        draft = PlatformBindingFormDraft(binding: updated)
        draft.publishStatus = .needsUpdate
        draft.publishUrl = ""
        draft.publishNotes = ""
        draft.hasLastPublishedAt = false
        try await viewModel.updateBinding(id: binding.id, draft: draft)

        updated = try #require(viewModel.bindings.first)
        #expect(updated.publishStatus == .needsUpdate)
        #expect(updated.publishUrl == nil)
        #expect(updated.publishNotes == nil)
        #expect(updated.lastPublishedAt == nil)
    }

    @Test("删除账号同时移除当前项目绑定")
    func deletingAccountRemovesBindings() async throws {
        let environment = try makeEnvironment()
        let viewModel = PlatformsTabViewModel(
            store: environment.store,
            projectId: environment.projectId
        )
        try await viewModel.addAccount(PlatformAccountFormDraft(platform: .wechatOA))
        let account = try #require(viewModel.accounts.first)
        await viewModel.bind(accountId: account.id)
        #expect(viewModel.bindings.count == 1)

        await viewModel.deleteAccount(id: account.id)

        #expect(viewModel.accounts.isEmpty)
        #expect(viewModel.bindings.isEmpty)
    }

    @Test("重复绑定和保存失败产生可展示错误")
    func mutationFailuresAreVisible() async throws {
        let environment = try makeEnvironment()
        let viewModel = PlatformsTabViewModel(
            store: environment.store,
            projectId: environment.projectId
        )
        try await viewModel.addAccount(PlatformAccountFormDraft(platform: .twitter))
        let account = try #require(viewModel.accounts.first)
        await viewModel.bind(accountId: account.id)
        await viewModel.bind(accountId: account.id)
        #expect(viewModel.saveError?.contains("绑定失败") == true)

        var invalid = PlatformAccountFormDraft(account: account)
        invalid.loginUrl = "not-a-url"
        await #expect(throws: PlatformStoreError.self) {
            try await viewModel.updateAccount(id: account.id, draft: invalid)
        }
        #expect(viewModel.saveError?.contains("更新失败") == true)
    }
}
