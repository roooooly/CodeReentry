import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("PlatformPresets")
struct PlatformPresetsTests {
    @Test func allFivePresetsPresent() {
        let presets = PlatformPresets.all
        #expect(presets.count == 5)
        let ids = Set(presets.map(\.platform))
        #expect(ids == [.wechatMini, .wechatOA, .wechatDevTools, .twitter, .xiaohongshu])
    }

    @Test func wechatDevToolsUsesOpenApp() {
        let p = PlatformPresets.preset(for: .wechatDevTools)!
        #expect(p.defaultLoginUrl == "weixin-devtools://")
        #expect(p.openKind == .openApp("WeChat DevTools"))
    }

    @Test func webPlatformsUseHttpsUrl() {
        let p = PlatformPresets.preset(for: .twitter)!
        #expect(p.defaultLoginUrl.hasPrefix("https://"))
        #expect(p.openKind == .openUrl)
    }

    @Test func displayNameZh() {
        #expect(PlatformPresets.preset(for: .xiaohongshu)?.defaultDisplayName == "小红书")
        #expect(PlatformPresets.preset(for: .wechatMini)?.defaultDisplayName == "微信小程序")
    }

    @Test func presetForUnknownReturnsNil() {
        // Platform 全 5 case 都有 preset；此测试确保 preset(for:) 在 all 中找到
        for p in Platform.allCases {
            #expect(PlatformPresets.preset(for: p) != nil)
        }
    }
}

@Suite("PublishStatus transitions (v1 allow-all)")
struct PublishStatusTransitionTests {
    @Test func legalTransitions() {
        #expect(PublishStatus.draft.canTransition(to: .inReview))
        #expect(PublishStatus.draft.canTransition(to: .published))
        #expect(PublishStatus.inReview.canTransition(to: .published))
        #expect(PublishStatus.published.canTransition(to: .needsUpdate))
        #expect(PublishStatus.needsUpdate.canTransition(to: .published))
    }

    @Test func anyToSelfAllowed() {
        for s in [PublishStatus.draft, .inReview, .published, .needsUpdate] {
            #expect(s.canTransition(to: s))
        }
    }
}

@MainActor
func makePlatformContainer() throws -> ModelContainer {
    try ModelContainer(
        for: PlatformAccount.self, ProjectPlatformBinding.self, Project.self,
             Tool.self, Subscription.self, SessionIndex.self, AppSettings.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
}

@Suite("PlatformStore accounts")
@MainActor
struct PlatformStoreAccountTests {

    @Test func createAccountPersists() async throws {
        let container = try makePlatformContainer()
        let store = PlatformStore(modelContainer: container)
        _ = try await store.createAccount(platform: .xiaohongshu,
                                          displayName: "我的小红书号",
                                          loginUrl: "https://creator.xiaohongshu.com/")
        let all = try await store.allAccounts()
        #expect(all.count == 1)
        #expect(all.first?.displayName == "我的小红书号")
    }

    @Test func updateAccountDisplayName() async throws {
        let container = try makePlatformContainer()
        let store = PlatformStore(modelContainer: container)
        let acc = try await store.createAccount(platform: .twitter, displayName: "old", loginUrl: "https://x.com/")
        try await store.updateAccount(
            id: acc.id,
            platform: .xiaohongshu,
            displayName: "new",
            loginUrl: "https://creator.xiaohongshu.com/login"
        )
        let got = try await store.account(id: acc.id)
        #expect(got?.displayName == "new")
        #expect(got?.platform == .xiaohongshu)
        #expect(got?.loginUrl == "https://creator.xiaohongshu.com/login")
    }

    @Test func deleteAccount() async throws {
        let container = try makePlatformContainer()
        let store = PlatformStore(modelContainer: container)
        let acc = try await store.createAccount(platform: .wechatOA, displayName: "a", loginUrl: "https://mp.weixin.qq.com/")
        try await store.deleteAccount(id: acc.id)
        #expect(try await store.allAccounts().isEmpty)
    }

    @Test func accountsByPlatform() async throws {
        let container = try makePlatformContainer()
        let store = PlatformStore(modelContainer: container)
        _ = try await store.createAccount(platform: .twitter, displayName: "t1", loginUrl: "https://x.com/1")
        _ = try await store.createAccount(platform: .twitter, displayName: "t2", loginUrl: "https://x.com/2")
        _ = try await store.createAccount(platform: .xiaohongshu, displayName: "x1", loginUrl: "https://creator.xiaohongshu.com/")
        #expect(try await store.accounts(platform: .twitter).count == 2)
        #expect(try await store.accounts(platform: .xiaohongshu).count == 1)
    }

    @Test func rejectsInvalidAccountInputAndMissingUpdates() async throws {
        let container = try makePlatformContainer()
        let store = PlatformStore(modelContainer: container)

        do {
            _ = try await store.createAccount(platform: .twitter, displayName: "   ", loginUrl: "https://x.com/")
            Issue.record("空显示名应被拒绝")
        } catch let error as PlatformStoreError {
            #expect(error == .invalidDisplayName)
        }

        do {
            _ = try await store.createAccount(platform: .twitter, displayName: "X", loginUrl: "not-a-url")
            Issue.record("无协议 URL 应被拒绝")
        } catch let error as PlatformStoreError {
            #expect(error == .invalidLoginURL)
        }

        do {
            try await store.updateAccount(id: UUID(), displayName: "X", loginUrl: "https://x.com/")
            Issue.record("更新不存在账号应抛错")
        } catch let error as PlatformStoreError {
            #expect(error == .notFound)
        }
    }
}

@Suite("PlatformStore bindings")
struct PlatformStoreBindingTests {

    struct Env {
        let container: ModelContainer
        let store: PlatformStore
        let projectId: UUID
        let accountId: UUID
    }

    @MainActor
    func makeEnv() async throws -> Env {
        let container = try makePlatformContainer()
        let ctx = container.mainContext
        let project = Project(stableId: "s1", name: "ExampleApp", path: "/tmp/ExampleApp")
        ctx.insert(project)
        try ctx.save()
        let store = PlatformStore(modelContainer: container)
        let account = try await store.createAccount(platform: .twitter, displayName: "t", loginUrl: "https://x.com/")
        return Env(container: container, store: store, projectId: project.id, accountId: account.id)
    }

    @Test func bindAccountToProject() async throws {
        let env = try await makeEnv()
        let binding = try await env.store.bind(projectId: env.projectId,
                                               accountId: env.accountId, status: .draft)
        #expect(binding.publishStatus == .draft)
        let list = try await env.store.bindings(projectId: env.projectId)
        #expect(list.count == 1)
    }

    @Test func cannotCreateDuplicateBinding() async throws {
        let env = try await makeEnv()
        _ = try await env.store.bind(projectId: env.projectId, accountId: env.accountId, status: .draft)
        do {
            _ = try await env.store.bind(projectId: env.projectId, accountId: env.accountId, status: .draft)
            Issue.record("应抛 duplicateBinding")
        } catch let err as PlatformStoreError {
            #expect(err == .duplicateBinding)
        } catch {
            Issue.record("意外错误: \(error)")
        }
    }

    @Test func updateStatusAndUrl() async throws {
        let env = try await makeEnv()
        let b = try await env.store.bind(projectId: env.projectId, accountId: env.accountId, status: .draft)
        try await env.store.updateBinding(id: b.id, status: .published,
                                          publishUrl: "https://x.com/u/status/1", notes: "首发")
        let got = try await env.store.binding(id: b.id)
        #expect(got?.publishStatus == .published)
        #expect(got?.publishUrl == "https://x.com/u/status/1")
        #expect(got?.publishNotes == "首发")
        #expect(got?.lastPublishedAt != nil)
    }

    @Test func deleteBinding() async throws {
        let env = try await makeEnv()
        let b = try await env.store.bind(projectId: env.projectId, accountId: env.accountId, status: .draft)
        try await env.store.deleteBinding(id: b.id)
        #expect(try await env.store.bindings(projectId: env.projectId).isEmpty)
    }

    @Test func explicitBindingUpdateCanSetAndClearLastPublishedAt() async throws {
        let env = try await makeEnv()
        let binding = try await env.store.bind(
            projectId: env.projectId,
            accountId: env.accountId,
            status: .draft
        )
        let publishedAt = Date(timeIntervalSince1970: 1_700_000_000)

        try await env.store.updateBinding(
            id: binding.id,
            update: PlatformBindingUpdate(
                publishStatus: .published,
                publishUrl: "  https://x.com/u/status/2  ",
                publishNotes: "  第二次发布  ",
                lastPublishedAt: publishedAt
            )
        )
        var updated = try #require(try await env.store.binding(id: binding.id))
        #expect(updated.publishStatus == .published)
        #expect(updated.publishUrl == "https://x.com/u/status/2")
        #expect(updated.publishNotes == "第二次发布")
        #expect(updated.lastPublishedAt == publishedAt)

        try await env.store.updateBinding(
            id: binding.id,
            update: PlatformBindingUpdate(
                publishStatus: .needsUpdate,
                publishUrl: " ",
                publishNotes: "",
                lastPublishedAt: nil
            )
        )
        updated = try #require(try await env.store.binding(id: binding.id))
        #expect(updated.publishStatus == .needsUpdate)
        #expect(updated.publishUrl == nil)
        #expect(updated.publishNotes == nil)
        #expect(updated.lastPublishedAt == nil)
    }

    @Test func deletingAccountAlsoDeletesItsBindings() async throws {
        let env = try await makeEnv()
        _ = try await env.store.bind(
            projectId: env.projectId,
            accountId: env.accountId,
            status: .draft
        )

        try await env.store.deleteAccount(id: env.accountId)

        #expect(try await env.store.account(id: env.accountId) == nil)
        #expect(try await env.store.bindings(projectId: env.projectId).isEmpty)
    }
}
