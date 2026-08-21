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
        _ = deps.reentryTrials
        // adapter 工厂与会话 reader 覆盖所有可恢复的内置工具。
        #expect(deps.adapter(for: "codex") != nil)
        #expect(deps.adapter(for: "claude-code") != nil)
        #expect(deps.adapter(for: "vscode") != nil)
        #expect(deps.adapter(for: "zcode") != nil)
        #expect(deps.adapter(for: "kimi") != nil)
        #expect(deps.adapter(for: "opencode") != nil)
        #expect(deps.adapter(for: "gemini-cli") != nil)
        #expect(deps.adapter(for: "github-copilot") != nil)
        #expect(deps.adapter(for: "aider") != nil)
        #expect(deps.adapter(for: "cline") != nil)
        #expect(deps.adapter(for: "goose") != nil)
        #expect(deps.sessionReader(forToolId: "opencode")?.toolId == "opencode")
        #expect(deps.sessionReader(forToolId: "gemini-cli")?.toolId == "gemini-cli")
        #expect(deps.sessionReader(forToolId: "github-copilot")?.toolId == "github-copilot")
        #expect(deps.sessionReader(forToolId: "aider")?.toolId == "aider")
        #expect(deps.sessionReader(forToolId: "cline")?.toolId == "cline")
        #expect(deps.sessionReader(forToolId: "goose")?.toolId == "goose")
    }

    @Test("Aider reader follows current registered roots but preserves test injection")
    func buildsAiderReaderFromRegistry() throws {
        let container = try Self.inMemoryContainer()
        let registered = Project(stableId: "aider-project", name: "Aider Project", path: "/tmp/Aider")
        let invalid = Project(stableId: "relative", name: "Relative", path: "relative/path")
        container.mainContext.insert(registered)
        container.mainContext.insert(invalid)
        try container.mainContext.save()

        let live = AppDependencies(modelContainer: container)
        let liveReader = try #require(live.sessionReader(forToolId: "aider") as? AiderReader)
        #expect(liveReader.projectRoots.map(\.path) == ["/tmp/Aider"])

        let injectedRoot = URL(fileURLWithPath: "/tmp/Injected-Aider", isDirectory: true)
        let injected = AppDependencies(
            modelContainer: container,
            sessionReaders: [AiderReader(projectRoots: [injectedRoot])]
        )
        let injectedReader = try #require(
            injected.sessionReader(forToolId: "aider") as? AiderReader
        )
        #expect(injectedReader.projectRoots.map(\.path) == ["/tmp/Injected-Aider"])
    }

    @Test("existing catalogs receive new defaults once and respect later deletion")
    func migratesNewDefaultsOnce() throws {
        let container = try Self.inMemoryContainer()
        let context = container.mainContext
        let project = Project(stableId: "stable", name: "P", path: "/tmp/P")
        let existing = Tool(
            name: "Existing Tool", kind: .cli, launchCommand: "/usr/bin/true",
            workingDirMode: .projectRoot, injectionMode: .clipboard, sortOrder: 4
        )
        context.insert(project)
        context.insert(existing)
        try context.save()

        let suite = "CodeReentry.AppDependencies.GeminiMigration.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        _ = AppDependencies(modelContainer: container, preferences: preferences)
        let migrated = try #require(
            try context.fetch(FetchDescriptor<Tool>()).first { $0.name == "Gemini CLI" }
        )
        let migratedCopilot = try #require(
            try context.fetch(FetchDescriptor<Tool>()).first {
                $0.name == "GitHub Copilot CLI"
            }
        )
        let migratedAider = try #require(
            try context.fetch(FetchDescriptor<Tool>()).first { $0.name == "Aider" }
        )
        let migratedCline = try #require(
            try context.fetch(FetchDescriptor<Tool>()).first { $0.name == "Cline" }
        )
        let migratedGoose = try #require(
            try context.fetch(FetchDescriptor<Tool>()).first { $0.name == "Goose" }
        )
        #expect(migrated.projects.map(\.stableId) == ["stable"])
        #expect(migratedCopilot.projects.map(\.stableId) == ["stable"])
        #expect(migratedAider.projects.map(\.stableId) == ["stable"])
        #expect(migratedCline.projects.map(\.stableId) == ["stable"])
        #expect(migratedGoose.projects.map(\.stableId) == ["stable"])
        #expect(try context.fetchCount(FetchDescriptor<Tool>()) == 6)

        context.delete(migrated)
        context.delete(migratedCopilot)
        context.delete(migratedAider)
        context.delete(migratedCline)
        context.delete(migratedGoose)
        try context.save()
        _ = AppDependencies(modelContainer: container, preferences: preferences)

        #expect(try context.fetchCount(FetchDescriptor<Tool>()) == 1)
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

    @Test("session resume uses persisted executable, environment and configured Tool")
    func sessionResumeUsesPersistedToolConfiguration() async throws {
        let container = try Self.inMemoryContainer()
        let deps = AppDependencies(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-reentry-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configured = try #require(
            try container.mainContext.fetch(FetchDescriptor<Tool>())
                .first { ToolIdentifierResolver.matches($0, sessionToolIdentifier: "claude-code") }
        )
        configured.launchCommand = "/bin/sh --noprofile"
        configured.detectPath = "/bin/sh"
        configured.envVars = ["CODE_REENTRY_TEST": "configured"]
        try container.mainContext.save()

        let adapter = MockToolAdapter(
            toolId: "claude-code", executablePath: "/missing/default/claude",
            requiresPTY: true, capabilities: [.canResume]
        )
        let terminal = TerminalController()
        terminal.executor = { _ in [:] }
        deps.overrideServices(adapters: ["claude-code": adapter], terminalController: terminal)

        try await deps.resumeSession(
            toolId: "claude-code",
            sessionId: "session-1",
            projectPath: root.path,
            configuredToolId: configured.id
        )

        #expect(adapter.resumeCount == 1)
        #expect(adapter.lastResumeSessionId == "session-1")
        #expect(adapter.lastResumeCtx?.tool?.id == configured.id)
        #expect(adapter.lastResumeCtx?.tool?.launchCommand == "/bin/sh --noprofile")
        #expect(adapter.lastResumeCtx?.environment["CODE_REENTRY_TEST"] == "configured")
        #expect(adapter.lastResumeCtx?.projectPath == root.path)
        #expect(terminal.lastLauncherPath == adapter.stubbedLauncherPath)
    }

    @Test("session resume rejects a missing working directory before opening Terminal")
    func sessionResumeRejectsMissingDirectory() async throws {
        let deps = try AppDependencies(modelContainer: Self.inMemoryContainer())
        let adapter = MockToolAdapter(
            toolId: "claude-code", executablePath: "/bin/sh",
            requiresPTY: true, capabilities: [.canResume]
        )
        deps.overrideServices(adapters: ["claude-code": adapter])

        await #expect(throws: SessionLaunchError.workingDirectoryMissing("/missing/code-reentry")) {
            try await deps.resumeSession(
                toolId: "claude-code",
                sessionId: "session-1",
                projectPath: "/missing/code-reentry"
            )
        }
        #expect(adapter.resumeCount == 0)
        #expect(deps.terminalController.lastLauncherPath == nil)
    }

    @Test("session resume rejects a missing configured executable before opening Terminal")
    func sessionResumeRejectsMissingExecutable() async throws {
        let container = try Self.inMemoryContainer()
        let deps = AppDependencies(modelContainer: container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("code-reentry-missing-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configured = try #require(
            try container.mainContext.fetch(FetchDescriptor<Tool>())
                .first { ToolIdentifierResolver.matches($0, sessionToolIdentifier: "claude-code") }
        )
        configured.launchCommand = "/missing/code-reentry/claude"
        configured.detectPath = nil
        try container.mainContext.save()
        let adapter = MockToolAdapter(
            toolId: "claude-code", executablePath: "/missing/default/claude",
            requiresPTY: true, capabilities: [.canResume]
        )
        deps.overrideServices(adapters: ["claude-code": adapter])

        await #expect(throws: SessionLaunchError.toolNotInstalled("Claude Code")) {
            try await deps.resumeSession(
                toolId: "claude-code",
                sessionId: "session-1",
                projectPath: root.path,
                configuredToolId: configured.id
            )
        }
        #expect(adapter.resumeCount == 0)
        #expect(deps.terminalController.lastLauncherPath == nil)
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

    @Test("Terminal automation failure preserves a copyable one-time fallback")
    func terminalAutomationFailureOffersManualFallback() async throws {
        let deps = try AppDependencies(modelContainer: Self.inMemoryContainer())
        let terminal = TerminalController()
        terminal.executor = { _ in
            throw TerminalController.TerminalError.executionFailed("Not authorized")
        }
        let pasteboard = RecordingPasteboard()
        deps.overrideServices(
            terminalController: terminal,
            pasteboardHelper: pasteboard
        )
        let launcherPath = "/tmp/CodeReentry fallback/it's-ready.sh"

        do {
            try await deps.executeCLI(launcherPath: launcherPath)
            Issue.record("Terminal automation failure should be surfaced")
        } catch let error as TerminalLaunchError {
            #expect(error == .automationFailed(launcherPath: launcherPath))
            #expect(error.recoveryLauncherPath == launcherPath)
            let presentation = TerminalLaunchFailure(error)
            #expect(presentation.launcherPath == launcherPath)
            #expect(!presentation.message.isEmpty)
        }

        deps.copyTerminalFallbackCommand(launcherPath: launcherPath)
        #expect(
            pasteboard.writtenText
                == #"/bin/bash '/tmp/CodeReentry fallback/it'\''s-ready.sh'"#
        )
    }

    // MARK: - helpers

    private final class RecordingPasteboard: PasteboardHandling {
        var writtenText: String?

        func write(text: String) { writtenText = text }
        func clearIfUnchanged(after delay: TimeInterval) async {}
    }

    static func inMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
