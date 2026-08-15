import Testing
import Foundation
import Security
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("Settings ViewModel")
@MainActor
struct SettingsViewTests {

    @Test("保存通用设置 → AppSettings 字段更新")
    func saveGeneral() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let vm = SettingsViewModel()
        try vm.load(ctx: env.ctx, deps: env.deps)

        vm.general.projectsRoot = "~/Code"
        vm.general.theme = "dark"
        vm.general.locale = "zh-CN"
        try vm.saveGeneral(ctx: env.ctx, deps: env.deps)

        let saved = try env.ctx.fetch(FetchDescriptor<AppSettings>()).first
        #expect(saved?.projectsRoot == "~/Code")
        #expect(saved?.theme == "dark")
        #expect(saved?.locale == "zh-CN")
    }

    @Test("英文语言写入设置与启动偏好，并提示重启")
    func englishLanguagePersistsAndRequestsRestart() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let vm = SettingsViewModel()
        try vm.load(ctx: env.ctx, deps: env.deps)

        vm.general.locale = AppLanguage.english.rawValue
        try vm.saveGeneral(ctx: env.ctx, deps: env.deps)

        let saved = try env.ctx.fetch(FetchDescriptor<AppSettings>()).first
        #expect(saved?.locale == "en")
        #expect(env.preferences.string(forKey: AppLanguage.preferenceKey) == "en")
        let persistedAppleLanguages = env.preferences
            .persistentDomain(forName: env.preferencesSuiteName)?["AppleLanguages"] as? [String]
        #expect(persistedAppleLanguages == ["en"])
        #expect(vm.languageChangeRequiresRestart == true)
    }

    @Test("跟随系统会移除应用级 AppleLanguages 覆盖")
    func systemLanguageRemovesAppleLanguagesOverride() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let inheritedAppleLanguages = env.preferences.stringArray(forKey: "AppleLanguages")
        AppLanguage.apply(.english, to: env.preferences)

        AppLanguage.apply(.system, to: env.preferences)

        #expect(env.preferences.string(forKey: AppLanguage.preferenceKey) == "system")
        #expect(env.preferences.stringArray(forKey: "AppleLanguages") == inheritedAppleLanguages)
    }

    @Test("登录项状态可注入，切换失败会回读真实状态")
    func launchAtLoginStateAndError() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let manager = StubLaunchAtLoginManager(state: .enabled)
        env.deps.overrideServices(launchAtLoginManager: manager)
        let vm = SettingsViewModel()

        try vm.load(ctx: env.ctx, deps: env.deps)
        #expect(vm.launchAtLoginRequested == true)

        try vm.setLaunchAtLogin(false, deps: env.deps)
        #expect(manager.requests == [false])
        #expect(vm.launchAtLoginState == .disabled)

        manager.nextState = .requiresApproval
        manager.nextError = .requiresApproval
        #expect(throws: LaunchAtLoginError.requiresApproval) {
            try vm.setLaunchAtLogin(true, deps: env.deps)
        }
        #expect(vm.launchAtLoginState == .requiresApproval)
        #expect(vm.launchAtLoginRequested == true)
    }

    @Test("日志导出必须先确认隐私提示")
    func logExportRequiresPrivacyConfirmation() async throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let exporter = RecordingLogExporter()
        env.deps.overrideServices(logExporter: exporter)
        let vm = SettingsViewModel()
        let destination = URL(fileURLWithPath: "/tmp/DevHub-test.ndjson")

        do {
            _ = try await vm.exportLastSevenDaysOfLogs(
                to: destination,
                privacyConfirmed: false,
                deps: env.deps
            )
            Issue.record("Expected privacy confirmation error")
        } catch let error as SettingsActionError {
            #expect(error == .logExportPrivacyConfirmationRequired)
        }
        #expect(await exporter.exportCallCount() == 0)
        #expect(vm.isExportingLogs == false)

        let result = try await vm.exportLastSevenDaysOfLogs(
            to: destination,
            privacyConfirmed: true,
            deps: env.deps
        )
        #expect(result.url == destination)
        #expect(await exporter.exportCallCount() == 1)
        #expect(vm.isExportingLogs == false)
    }

    @Test("添加 secretEnvKey → 写 Keychain，不回显值")
    func addSecretKey() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let vm = SettingsViewModel()
        try vm.load(ctx: env.ctx, deps: env.deps)
        let tool = ToolFixtures.codexSample
        env.ctx.insert(tool)
        try env.ctx.save()

        defer { _ = try? env.deps.keychain.delete(toolId: tool.id.uuidString, envKey: "OPENAI_API_KEY") }

        try vm.addSecretEnvKey(tool: tool, envKey: "OPENAI_API_KEY", value: "sk-secret", deps: env.deps)

        // 工具的 secretEnvKeys 包含此 key
        #expect(tool.secretEnvKeys.contains("OPENAI_API_KEY"))
        // Keychain 存了值（Core account = "<toolId>.<envKey>"）
        let stored = try env.deps.keychain.get(toolId: tool.id.uuidString, envKey: "OPENAI_API_KEY")
        #expect(stored == "sk-secret")
        // UI 不暴露明文，只显示真实 Keychain 状态
        #expect(vm.secretDisplay(tool: tool, envKey: "OPENAI_API_KEY", deps: env.deps)
                == "••••• " + String(localized: "已存储"))
    }

    @Test("Keychain 写入失败时不提交密钥引用")
    func failedSecretWriteDoesNotCommitModel() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let keychain = StubKeychainStore()
        keychain.failNextSet = true
        env.deps.overrideServices(keychain: keychain)
        let vm = SettingsViewModel()
        try vm.load(ctx: env.ctx, deps: env.deps)
        let tool = ToolFixtures.codexSample
        env.ctx.insert(tool)
        try env.ctx.save()

        do {
            try vm.addSecretEnvKey(tool: tool, envKey: "OPENAI_API_KEY", value: "sk-secret", deps: env.deps)
            Issue.record("Expected Keychain write failure")
        } catch {
            #expect(error.localizedDescription == StubKeychainError.writeFailed.localizedDescription)
        }

        #expect(tool.secretEnvKeys.isEmpty)
        #expect(try keychain.get(toolId: tool.id.uuidString, envKey: "OPENAI_API_KEY") == nil)
        let persisted = try env.ctx.fetch(FetchDescriptor<Tool>()).first { $0.id == tool.id }
        #expect(persisted?.secretEnvKeys.isEmpty == true)
    }

    @Test("密钥表单失败时保留输入和错误，且不触发成功关闭")
    func secretEntryFailureKeepsDraft() {
        let form = SecretEntryFormModel()
        form.value = "still-here"
        var didClose = false

        if form.submit({ _ in throw StubKeychainError.writeFailed }) {
            didClose = true
        }

        #expect(didClose == false)
        #expect(form.value == "still-here")
        #expect(form.errorMessage == StubKeychainError.writeFailed.localizedDescription)
        #expect(form.isSubmitting == false)
    }

    @Test("备份只恢复 key 名时显示未设置")
    func restoredSecretNameWithoutValue() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let vm = SettingsViewModel()
        try vm.load(ctx: env.ctx, deps: env.deps)
        let tool = ToolFixtures.codexSample
        tool.secretEnvKeys = ["MISSING_KEYCHAIN_VALUE"]
        env.ctx.insert(tool)
        try env.ctx.save()

        #expect(vm.secretDisplay(tool: tool, envKey: "MISSING_KEYCHAIN_VALUE", deps: env.deps)
                == String(localized: "未设置"))
    }

    @Test("添加自定义 CLI 后绑定所有已有项目")
    func addCustomTool() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let project = Project(stableId: "project", name: "Project", path: "/tmp/project")
        env.ctx.insert(project)
        try env.ctx.save()
        let vm = SettingsViewModel()
        try vm.load(ctx: env.ctx, deps: env.deps)

        let tool = try vm.addTool(kind: .cli, ctx: env.ctx)

        #expect(tool.kind == .cli)
        #expect(tool.projects.map(\.stableId) == ["project"])
        #expect(vm.tools.contains { $0.id == tool.id })
    }

    @Test("更新 secretEnvKey → 覆盖 Keychain 值")
    func updateSecretKey() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let vm = SettingsViewModel()
        try vm.load(ctx: env.ctx, deps: env.deps)
        let tool = ToolFixtures.codexSample
        env.ctx.insert(tool)
        try env.ctx.save()

        defer { _ = try? env.deps.keychain.delete(toolId: tool.id.uuidString, envKey: "K") }

        try vm.addSecretEnvKey(tool: tool, envKey: "K", value: "v1", deps: env.deps)
        try vm.updateSecretEnvKey(tool: tool, envKey: "K", value: "v2", deps: env.deps)

        let stored = try env.deps.keychain.get(toolId: tool.id.uuidString, envKey: "K")
        #expect(stored == "v2")
    }

    @Test("更新密钥失败时保留旧值")
    func failedSecretUpdatePreservesOldValue() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let keychain = StubKeychainStore()
        env.deps.overrideServices(keychain: keychain)
        let vm = SettingsViewModel()
        try vm.load(ctx: env.ctx, deps: env.deps)
        let tool = ToolFixtures.codexSample
        tool.secretEnvKeys = ["K"]
        env.ctx.insert(tool)
        try env.ctx.save()
        _ = try keychain.set(toolId: tool.id.uuidString, envKey: "K", value: "old")
        keychain.failNextSet = true

        do {
            try vm.updateSecretEnvKey(tool: tool, envKey: "K", value: "new", deps: env.deps)
            Issue.record("Expected Keychain update failure")
        } catch {
            #expect(error.localizedDescription == StubKeychainError.writeFailed.localizedDescription)
        }

        #expect(try keychain.get(toolId: tool.id.uuidString, envKey: "K") == "old")
        #expect(tool.secretEnvKeys == ["K"])
    }

    @Test("删除 secretEnvKey → Keychain 清除 + 列表移除")
    func deleteSecretKey() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let vm = SettingsViewModel()
        try vm.load(ctx: env.ctx, deps: env.deps)
        let tool = ToolFixtures.codexSample
        env.ctx.insert(tool)
        try env.ctx.save()

        try vm.addSecretEnvKey(tool: tool, envKey: "K", value: "v", deps: env.deps)
        try vm.deleteSecretEnvKey(tool: tool, envKey: "K", deps: env.deps)

        #expect(tool.secretEnvKeys.contains("K") == false)
        #expect(try env.deps.keychain.get(toolId: tool.id.uuidString, envKey: "K") == nil)
    }

    @Test("MCP 与插件 tab 均已启用（无 placeholder）")
    func mcpAndPluginsEnabled() {
        #expect(SettingsTab.mcp.placeholderStage == nil)
        #expect(SettingsTab.mcp.isEnabled == true)
        #expect(SettingsTab.plugins.placeholderStage == nil)
        #expect(SettingsTab.plugins.isEnabled == true)
    }

    @Test("侧边栏插件入口会把设置窗口路由到插件 tab")
    func consumeRequestedPluginsTab() throws {
        let env = try SettingsViewTests.makeSettingsEnv()
        let vm = SettingsViewModel()
        env.deps.requestedSettingsTab = .plugins

        vm.consumeRequestedTab(from: env.deps)

        #expect(vm.selectedTab == .plugins)
        #expect(env.deps.requestedSettingsTab == nil)
    }

    // MARK: - env

    struct SettingsEnv {
        let container: ModelContainer
        let ctx: ModelContext
        let deps: AppDependencies
        let preferences: UserDefaults
        let preferencesSuiteName: String
    }

    static func makeSettingsEnv() throws -> SettingsEnv {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let suiteName = "SettingsViewTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        preferences.removePersistentDomain(forName: suiteName)
        let deps = AppDependencies(modelContainer: container, preferences: preferences)
        _ = try? deps.ensureAppSettings(in: ctx)
        return SettingsEnv(
            container: container,
            ctx: ctx,
            deps: deps,
            preferences: preferences,
            preferencesSuiteName: suiteName
        )
    }
}

@MainActor
private final class StubLaunchAtLoginManager: LaunchAtLoginManaging {
    var state: LaunchAtLoginState
    var requests: [Bool] = []
    var nextState: LaunchAtLoginState?
    var nextError: LaunchAtLoginError?

    init(state: LaunchAtLoginState) {
        self.state = state
    }

    func setEnabled(_ enabled: Bool) throws {
        requests.append(enabled)
        state = nextState ?? (enabled ? .enabled : .disabled)
        nextState = nil
        if let nextError {
            self.nextError = nil
            throw nextError
        }
    }
}

private actor RecordingLogExporter: DevHubLogExporting {
    private var calls = 0

    func exportLastSevenDays(to destination: URL) async throws -> DevHubLogExportResult {
        calls += 1
        return DevHubLogExportResult(url: destination, byteCount: 0)
    }

    func exportCallCount() -> Int {
        calls
    }
}

private enum StubKeychainError: LocalizedError {
    case writeFailed

    var errorDescription: String? {
        String(localized: "模拟 Keychain 写入失败")
    }
}

private final class StubKeychainStore: KeychainStoring, @unchecked Sendable {
    var values: [String: String] = [:]
    var failNextSet = false

    @discardableResult
    func set(toolId: String, envKey: String, value: String) throws -> OSStatus {
        if failNextSet {
            failNextSet = false
            throw StubKeychainError.writeFailed
        }
        values[KeychainStore.account(toolId: toolId, envKey: envKey)] = value
        return errSecSuccess
    }

    func get(toolId: String, envKey: String) throws -> String? {
        values[KeychainStore.account(toolId: toolId, envKey: envKey)]
    }

    @discardableResult
    func delete(toolId: String, envKey: String) throws -> OSStatus {
        values.removeValue(forKey: KeychainStore.account(toolId: toolId, envKey: envKey))
        return errSecSuccess
    }
}

/// 工具 fixture（codex 样本）
enum ToolFixtures {
    static var codexSample: Tool {
        Tool(
            name: "codex", kind: .cli,
            launchCommand: "/Applications/ChatGPT.app/Contents/Resources/codex",
            workingDirMode: .projectRoot,
            injectMemory: true, injectionMode: .positionalArg,
            secretEnvKeys: [], enabled: true, sortOrder: 0
        )
    }
}
