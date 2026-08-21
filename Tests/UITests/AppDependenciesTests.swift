import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("AppDependencies")
@MainActor
struct AppDependenciesTests {

    @Test("makeShared 返回非空容器，包含所有必需服务")
    func makeSharedReturnsConfiguredContainer() throws {
        let deps = try AppDependencies(modelContainer: Self.inMemoryContainer())
        _ = deps.modelContainer
        // 无参 Core 服务为值类型，非空即可
        _ = deps.gitStatusProvider
        _ = deps.keychain
        // adapter 工厂与会话 reader 均覆盖 OpenCode 恢复路径。
        #expect(deps.adapter(for: "codex") != nil)
        #expect(deps.adapter(for: "claude-code") != nil)
        #expect(deps.adapter(for: "vscode") != nil)
        #expect(deps.adapter(for: "zcode") != nil)
        #expect(deps.adapter(for: "kimi") != nil)
        #expect(deps.adapter(for: "opencode") != nil)
        #expect(deps.sessionReader(forToolId: "opencode")?.toolId == "opencode")
    }

    @Test("adapter(for:) zcode/kimi 返回正确类型 + capabilities 符合预期")
    func zcodeAndKimiAdaptersResolve() async throws {
        let deps = try AppDependencies(modelContainer: Self.inMemoryContainer())
        // zcode：CLI adapter，可 resume + 可注入位置参数
        let zcode = try #require(deps.adapter(for: "zcode"))
        #expect(zcode.toolId == "zcode")
        #expect(zcode.capabilities.contains(.canResume))
        #expect(zcode.capabilities.contains(.canInjectPositional))
        // kimi：GUI-only adapter
        let kimi = try #require(deps.adapter(for: "kimi"))
        #expect(kimi.toolId == "kimi")
        #expect(kimi.capabilities == .canOpenGUI)
    }

    @Test("AppSettings 单例在空数据库时自动创建，字段为默认值")
    @MainActor
    func appSettingsSingletonAutoCreated() throws {
        let container = try Self.inMemoryContainer()
        let deps = AppDependencies(modelContainer: container)
        let ctx = container.mainContext

        let settings = try deps.ensureAppSettings(in: ctx)
        #expect(settings.id == AppSettings.singletonId)
        #expect(settings.projectsRoot == "~/Projects")
        #expect(settings.locale == "zh-CN")
        #expect(settings.theme == "system")
        // 第二次调用返回同一对象（幂等）
        let again = try deps.ensureAppSettings(in: ctx)
        #expect(again.id == settings.id)
    }

    @Test("memoryStore(for:) 用项目路径构造 per-project MemoryStore")
    func memoryStoreIsPerProject() throws {
        let deps = try AppDependencies(modelContainer: Self.inMemoryContainer())
        let storeA = deps.memoryStore(forProjectPath: "/tmp/projA")
        let storeB = deps.memoryStore(forProjectPath: "/tmp/projB")
        #expect(storeA.projectRoot.path == "/tmp/projA")
        #expect(storeB.projectRoot.path == "/tmp/projB")
        #expect(storeA.projectRoot != storeB.projectRoot)
    }

    @Test("切换项目或全局入口会清理旧的会话选择")
    func navigationClearsSelectedSession() throws {
        let deps = try AppDependencies(modelContainer: Self.inMemoryContainer())
        deps.selectedProjectStableId = "project-a"
        deps.selectedSessionId = "session-a"

        deps.selectedProjectStableId = "project-b"
        #expect(deps.selectedSessionId == nil)

        deps.selectedSessionId = "session-b"
        deps.selectedGlobalDestination = .sessions
        #expect(deps.selectedSessionId == nil)
        #expect(deps.selectedProjectStableId == nil)
    }

    @Test("详情模块开关写入 UserDefaults，并拒绝关闭最后一个模块")
    func detailTabVisibilityPersistsAndKeepsOneEnabled() throws {
        let suiteName = "io.github.roooooly.devhub.tests.tabs.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        preferences.removePersistentDomain(forName: suiteName)
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let deps = AppDependencies(
            modelContainer: try Self.inMemoryContainer(),
            preferences: preferences
        )
        #expect(deps.enabledDetailTabs == DetailTab.allCases)
        #expect(deps.disabledDetailTabs.isEmpty)

        try deps.setDetailTab(.sessions, enabled: false)
        try deps.setDetailTab(.memory, enabled: false)
        #expect(deps.enabledDetailTabs == [.tools, .subscriptions, .platforms, .ops])
        #expect(deps.disabledDetailTabs == [.sessions, .memory])

        let reloaded = AppDependencies(
            modelContainer: try Self.inMemoryContainer(),
            preferences: preferences
        )
        #expect(reloaded.disabledDetailTabs == [.sessions, .memory])

        for tab in reloaded.enabledDetailTabs where tab != .tools {
            try reloaded.setDetailTab(tab, enabled: false)
        }
        #expect(reloaded.enabledDetailTabs == [.tools])
        #expect(throws: DetailTabVisibilityError.cannotDisableLastTab) {
            try reloaded.setDetailTab(.tools, enabled: false)
        }
        #expect(reloaded.enabledDetailTabs == [.tools])
    }

    @Test("损坏的全关闭偏好会自动恢复 Tools")
    func corruptedTabPreferencesFallBackToTools() throws {
        let suiteName = "io.github.roooooly.devhub.tests.tabs-corrupt.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        preferences.removePersistentDomain(forName: suiteName)
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(
            DetailTab.allCases.map(\.rawValue),
            forKey: AppDependencies.disabledDetailTabsKey
        )

        let deps = AppDependencies(
            modelContainer: try Self.inMemoryContainer(),
            preferences: preferences
        )

        #expect(deps.enabledDetailTabs == [.tools])
        #expect(deps.isDetailTabEnabled(.tools))
    }

    @Test("onboardingCompleted 默认 false，可写回 UserDefaults")
    @MainActor
    func onboardingFlagRoundtrip() throws {
        let key = "devhub.onboarding.completed"
        let suiteName = "io.github.roooooly.devhub.tests.onboarding.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        preferences.removePersistentDomain(forName: suiteName)
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let deps = try AppDependencies(
            modelContainer: Self.inMemoryContainer(),
            preferences: preferences
        )
        #expect(deps.onboardingCompleted == false)
        deps.onboardingCompleted = true
        #expect(preferences.bool(forKey: key) == true)
        // 重新构造应读取已持久化值
        let deps2 = try AppDependencies(
            modelContainer: Self.inMemoryContainer(),
            preferences: preferences
        )
        #expect(deps2.onboardingCompleted == true)
    }

    // MARK: - helpers

    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
