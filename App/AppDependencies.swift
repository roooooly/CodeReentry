import Foundation
import SwiftData
import OSLog
import UserNotifications
import DevHubCore

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "app-deps")

/// UI 层获取 Core 服务的唯一入口。
///
/// 所有视图通过 `@Environment(AppDependencies.self)` 取得依赖。
/// 测试中可传入内存型 ModelContainer，并通过 `overrideServices(...)` 注入 mock 服务
/// （Core 的 `MemoryStore`/`GitStatusProvider`/`KeychainStore` 都是值类型 struct，
///  `ToolAdapter` 是 protocol，`TerminalController`/`GUIAppLauncher` 是 final class
///  且通过可注入的 executor/workspace 协议提供测试 seam——因此本类不靠子类化）。
@Observable
@MainActor
final class AppDependencies {

    private static let geminiCatalogMigrationKey =
        "DefaultToolCatalog.didMigrateGeminiCLI.v1"
    private static let copilotCatalogMigrationKey =
        "DefaultToolCatalog.didMigrateGitHubCopilotCLI.v1"

    // MARK: - Core 服务

    let modelContainer: ModelContainer
    let gitStatusProvider: GitStatusProvider
    private(set) var keychain: any KeychainStoring
    private let preferences: UserDefaults

    /// Terminal / GUI 启动器（final class，可注入 executor/workspace seam）。
    /// 生产用默认实例；测试可替换为注入了 no-op executor/workspace 的实例。
    ///
    /// 两者只通过这个 `@MainActor` 依赖容器和主线程 ViewModel 访问。
    private(set) var terminalController: TerminalController
    private(set) var guiLauncher: GUIAppLauncher
    /// 订阅 store（@ModelActor，绑定 modelContainer）。
    let subscriptionStore: SubscriptionStore
    /// 平台账号 + 绑定 store（@ModelActor）。
    let platformStore: PlatformStore
    /// 订阅续费提醒调度器（UNUserNotificationCenter 单例）。
    let reminderScheduler: ReminderScheduler
    /// 插件权限确认 store（actor，Settings 插件 tab 与命令面板共享同一实例）。
    let pluginPermissionStore: ScriptPluginPermissionStore
    /// Rail B MCP stdio 生命周期与工具调用入口。
    let mcpSupervisor: MCPClientSupervisor
    /// macOS 登录项管理（SMAppService.mainApp，测试可替换）。
    private(set) var launchAtLoginManager: any LaunchAtLoginManaging
    /// 最近 7 天 DevHub 统一日志导出器（测试可替换 command runner）。
    private(set) var logExporter: any DevHubLogExporting
    /// 自定义 CLI 的剪贴板记忆注入；写入后仅在内容未变化时自动清理。
    private(set) var pasteboardHelper: any PasteboardHandling
    /// 订阅用量与成本扫描器（纯本地解析 Claude/Codex JSONL，无网络/无凭据）。
    public let usageScanner: UsageScanner

    /// 测试用：替换 TerminalController（Core final class，只能整体替换引用）。
    func _replaceTerminalController(_ c: TerminalController) { terminalController = c }
    /// 测试用：替换 GUIAppLauncher。
    func _replaceGuiLauncher(_ l: GUIAppLauncher) { guiLauncher = l }

    // MARK: - UI 可观察状态

    /// 当前选中的项目 stableId。选择项目与全局入口互斥。
    var selectedProjectStableId: String? {
        didSet {
            if oldValue != selectedProjectStableId { selectedSessionId = nil }
            if selectedProjectStableId != nil { selectedGlobalDestination = nil }
        }
    }

    /// 当前选中的全局入口（订阅、会话或平台账号）。
    var selectedGlobalDestination: GlobalDestination? {
        didSet {
            if oldValue != selectedGlobalDestination { selectedSessionId = nil }
            if selectedGlobalDestination != nil { selectedProjectStableId = nil }
        }
    }

    /// 当前会话列表中选中的工具会话 ID，供 session-scope 插件动作使用。
    /// 切换项目或全局入口时会自动清空，避免把旧页面的会话传给插件。
    var selectedSessionId: String?

    /// 是否已完成首次运行引导
    var onboardingCompleted: Bool {
        didSet { preferences.set(onboardingCompleted, forKey: Self.onboardingKey) }
    }

    /// 主窗口可请求设置窗口打开到指定 tab。SettingsView 消费后会清空。
    var requestedSettingsTab: SettingsTab?

    /// 用户关闭的项目详情模块。仅存 UserDefaults，不进入 SwiftData schema。
    private(set) var disabledDetailTabs: Set<DetailTab>

    /// 按固定 UI 顺序返回当前启用模块；持久化数据异常时至少包含 Tools。
    var enabledDetailTabs: [DetailTab] {
        let enabled = DetailTab.allCases.filter { !disabledDetailTabs.contains($0) }
        return enabled.isEmpty ? [.tools] : enabled
    }

    // MARK: - 测试注入 seam（生产 nil = 用真实 Core）

    private var memoryStoreFactory: ((String) -> MemoryStore)?
    private var adapterOverrides: [String: any ToolAdapter] = [:]
    /// 项目扫描器工厂（Core ProjectScanner 绑定 rootURL，故为 factory）。
    private var scannerFactory: ((URL) -> ProjectScanner)?

    /// 已注册的会话 reader（§5.3A 聚合用）。P1 加 ZcodeReader。
    let sessionReaders: [any SessionReader]

    init(modelContainer: ModelContainer, preferences: UserDefaults = .standard) {
        self.modelContainer = modelContainer
        self.gitStatusProvider = GitStatusProvider()
        self.keychain = KeychainStore()
        self.preferences = preferences
        self.terminalController = TerminalController()
        self.guiLauncher = GUIAppLauncher()
        self.subscriptionStore = SubscriptionStore(modelContainer: modelContainer)
        self.platformStore = PlatformStore(modelContainer: modelContainer)
        self.reminderScheduler = ReminderScheduler(center: SystemNotificationCenter())
        self.pluginPermissionStore = ScriptPluginPermissionStore(file: ScriptPluginPermissionStore.defaultPermissionsFile)
        self.mcpSupervisor = MCPClientSupervisor()
        self.launchAtLoginManager = SystemLaunchAtLoginManager()
        self.logExporter = DevHubLogExporter()
        self.pasteboardHelper = PasteboardHelper()
        self.usageScanner = UsageScanner(projectPathsProvider: { [modelContainer] in
            // 只读快照：取出当前注册项目的根路径，供用量按 cwd 归桶到 perProject。
            let ctx = ModelContext(modelContainer)
            let projects = (try? ctx.fetch(FetchDescriptor<Project>())) ?? []
            return projects.map(\.path).filter { !$0.isEmpty }
        })
        // OpenCode 仅发现 SQLite 元数据；Gemini/Copilot 使用有界 JSONL reader。
        // 聚合只由用户显式刷新触发。
        let home = FileManager.default.homeDirectoryForCurrentUser
        let kimiPaths = KimiPathDiscovery.discover(
            candidates: KimiPathDiscovery.standardCandidates(home: home), home: home)
        self.sessionReaders = [
            ClaudeReader(), CodexReader(), ZcodeReader(), KimiReader(paths: kimiPaths),
            OpenCodeReader(homeURL: home), GeminiReader(homeURL: home),
            GitHubCopilotReader(homeURL: home)
        ]
        // A resource manager should open on a useful operating surface, not an
        // empty detail pane that asks the user to make a redundant choice.
        self.selectedGlobalDestination = .projects
        self.onboardingCompleted = preferences.bool(forKey: Self.onboardingKey)
        self.requestedSettingsTab = nil
        let storedDisabledTabs = Set(
            (preferences.stringArray(forKey: Self.disabledDetailTabsKey) ?? [])
                .compactMap(DetailTab.init(rawValue:))
        )
        // 手工编辑 defaults 或旧版本 bug 不得把所有入口都关掉。
        self.disabledDetailTabs = storedDisabledTabs.count == DetailTab.allCases.count
            ? storedDisabledTabs.subtracting([.tools])
            : storedDisabledTabs
        do {
            _ = try DefaultToolCatalog.seedIfNeeded(in: modelContainer.mainContext)
            if !preferences.bool(forKey: Self.geminiCatalogMigrationKey) {
                let existing = try modelContainer.mainContext.fetch(FetchDescriptor<Tool>())
                if !existing.contains(where: {
                    ToolIdentifierResolver.matches($0, sessionToolIdentifier: "gemini-cli")
                }) {
                    _ = try DefaultToolCatalog.restoreDefault(
                        named: "Gemini CLI", in: modelContainer.mainContext
                    )
                }
                preferences.set(true, forKey: Self.geminiCatalogMigrationKey)
            }
            if !preferences.bool(forKey: Self.copilotCatalogMigrationKey) {
                let existing = try modelContainer.mainContext.fetch(FetchDescriptor<Tool>())
                if !existing.contains(where: {
                    ToolIdentifierResolver.matches($0, sessionToolIdentifier: "github-copilot")
                }) {
                    _ = try DefaultToolCatalog.restoreDefault(
                        named: "GitHub Copilot CLI", in: modelContainer.mainContext
                    )
                }
                preferences.set(true, forKey: Self.copilotCatalogMigrationKey)
            }
        } catch {
            logger.error("初始化内置工具失败: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - 服务工厂

    /// 用项目路径构造 per-project `MemoryStore`（Core 的 MemoryStore 是绑定 projectRoot 的 struct）。
    func memoryStore(forProjectPath path: String) -> MemoryStore {
        if let factory = memoryStoreFactory { return factory(path) }
        let url = URL(fileURLWithPath: (path as NSString).standardizingPath)
        return MemoryStore(projectRoot: url)
    }

    /// 用根 URL 构造 `ProjectScanner`（Core 的 scanner 绑定 rootURL）。
    func projectScanner(rootURL: URL) -> ProjectScanner {
        if let factory = scannerFactory { return factory(rootURL) }
        return ProjectScanner(rootURL: rootURL)
    }

    /// 用给定 ModelContext 构造 `ProjectRegistry`（Core 的 registry 绑定 ctx）。
    func projectRegistry(in ctx: ModelContext) -> ProjectRegistry {
        ProjectRegistry(modelContext: ctx)
    }

    // MARK: - 项目详情模块可见性

    func isDetailTabEnabled(_ tab: DetailTab) -> Bool {
        !disabledDetailTabs.contains(tab)
    }

    /// 更新并立即持久化模块可见性。最后一个启用模块不可关闭。
    func setDetailTab(_ tab: DetailTab, enabled: Bool) throws {
        if enabled {
            guard disabledDetailTabs.contains(tab) else { return }
            disabledDetailTabs.remove(tab)
        } else {
            guard isDetailTabEnabled(tab) else { return }
            guard enabledDetailTabs.count > 1 else {
                throw DetailTabVisibilityError.cannotDisableLastTab
            }
            disabledDetailTabs.insert(tab)
        }

        preferences.set(
            DetailTab.allCases
                .filter { disabledDetailTabs.contains($0) }
                .map(\.rawValue),
            forKey: Self.disabledDetailTabsKey
        )
    }

    /// adapter 解析。优先测试覆盖，否则用真实 Core adapter。
    func adapter(for toolId: String) -> (any ToolAdapter)? {
        if let over = adapterOverrides[toolId] { return over }
        switch toolId {
        case "codex":       return CodexAdapter()
        case "claude-code": return ClaudeAdapter()
        case "claude":      return ClaudeAdapter()  // 容错别名
        case "zcode":       return ZcodeAdapter()
        case "kimi":        return KimiAdapter()
        case "vscode":      return VSCodeAdapter()
        case "opencode":    return OpenCodeAdapter()
        case "gemini-cli":  return GeminiAdapter()
        case "gemini":      return GeminiAdapter()
        case "github-copilot": return GitHubCopilotAdapter()
        case "copilot":        return GitHubCopilotAdapter()
        default:            return nil
        }
    }

    /// Resolve the enabled Tool record that owns a session. The record carries
    /// the user's executable override and launch environment; bypassing it makes
    /// resume behave differently from launching the same tool in the Tools tab.
    func configuredTool(forSessionToolId toolId: String, project: Project? = nil) -> Tool? {
        let candidates: [Tool]
        if let project {
            candidates = project.tools
        } else {
            candidates = (try? modelContainer.mainContext.fetch(FetchDescriptor<Tool>())) ?? []
        }
        return candidates
            .filter(\.enabled)
            .sorted { $0.sortOrder < $1.sortOrder }
            .first { ToolIdentifierResolver.matches($0, sessionToolIdentifier: toolId) }
    }

    /// Resume a CLI session through one guarded path shared by every session UI.
    /// This validates the cwd and executable before opening Terminal, and carries
    /// the persisted Tool configuration into the adapter.
    func resumeSession(
        toolId: String,
        sessionId: String,
        projectPath: String,
        configuredToolId: UUID? = nil,
        project: Project? = nil
    ) async throws {
        let workingDirectory = try Self.validWorkingDirectory(projectPath)
        guard let adapter = adapter(for: toolId) else {
            throw SessionLaunchError.adapterUnavailable(toolId)
        }
        guard adapter.capabilities.contains(.canResume) else {
            throw SessionLaunchError.resumeUnsupported(toolId)
        }
        let configuredById = configuredToolId.flatMap { id in
            ((try? modelContainer.mainContext.fetch(FetchDescriptor<Tool>())) ?? [])
                .first {
                    $0.id == id && $0.enabled
                        && ToolIdentifierResolver.matches($0, sessionToolIdentifier: toolId)
                }
        }
        guard let tool = configuredById ?? configuredTool(forSessionToolId: toolId, project: project) else {
            throw SessionLaunchError.toolNotConfigured(toolId)
        }
        guard case .found = ToolDetector().probe(
            executableHint: adapter.executablePath,
            detectPath: tool.detectPath,
            launchCommand: tool.launchCommand
        ) else {
            throw SessionLaunchError.toolNotInstalled(tool.name)
        }

        var environment = tool.envVars
        for key in tool.secretEnvKeys {
            guard let value = try keychain.get(toolId: tool.id.uuidString, envKey: key) else {
                throw SessionLaunchError.missingSecret(key)
            }
            environment[key] = value
        }
        let context = LaunchContext(
            projectPath: workingDirectory,
            renderedMemoryFile: nil,
            sessionId: sessionId,
            tool: tool,
            environment: environment
        )
        let instance = try await adapter.resume(sessionId: sessionId, ctx: context)
        switch instance {
        case .cli(let launcherPath):
            _ = try await terminalController.execute(terminal: .terminal, launcherPath: launcherPath)
        case .gui(let bundleId):
            try await guiLauncher.launchApp(bundleId: bundleId, projectPath: workingDirectory)
        }
    }

    private static func validWorkingDirectory(_ path: String) throws -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard !expanded.isEmpty,
              FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw SessionLaunchError.workingDirectoryMissing(path)
        }
        return (expanded as NSString).standardizingPath
    }

    /// 按会话工具 id 查 reader（SessionsTab 用：resume 需 reader.load 解析 detail）。
    func sessionReader(forToolId toolId: String) -> (any SessionReader)? {
        sessionReaders.first { $0.toolId == toolId }
    }

    /// 跑一轮会话聚合扫描（会话页面手动刷新调用）。
    /// 各 reader discover → 按 cwd 归到 Project → 写 SessionIndex。
    func runAggregation() async throws {
        let writer = SessionIndexWriter(modelContainer: modelContainer)
        let aggregator = SessionAggregator(readers: sessionReaders)
        var aggregationError: (any Error)?
        do {
            try await aggregator.aggregate(writer: writer, modelContext: modelContainer.mainContext)
        } catch {
            aggregationError = error
        }
        if let aggregationError { throw aggregationError }
    }

    /// 写渲染后的注入内容到临时文件，返回路径。
    /// Core 的 `LaunchContext.renderedMemoryFile` 接收路径，adapter 在 argv 里写入
    /// `$__DEVHUB_MEMORY_FILE__<path>` 占位，由 LauncherScriptBuilder 展开为 `$(cat '<path>')`。
    func writeInjectionFile(_ content: String) throws -> String {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("DevHub", isDirectory: true)
            .appendingPathComponent("injection", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        // 0600：注入文件含项目上下文，仅 owner 可读
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }

    // MARK: - AppSettings 单例

    /// 确保 AppSettings 单例存在；空数据库首次启动时创建默认值（幂等）。
    func ensureAppSettings(in ctx: ModelContext) throws -> AppSettings {
        try AppSettings.fetchOrCreate(in: ctx)
    }

    var preferredLanguage: AppLanguage {
        AppLanguage.stored(in: preferences)
    }

    func setPreferredLanguage(_ language: AppLanguage) {
        AppLanguage.apply(language, to: preferences)
    }

    func bootstrapPreferredLanguage(_ fallback: AppLanguage) {
        if preferences.string(forKey: AppLanguage.preferenceKey) == nil {
            AppLanguage.apply(fallback, to: preferences)
        }
    }

    // MARK: - 测试注入

    /// 仅测试用：替换服务工厂 / adapter / 启动器。生产实现保持默认真实 Core。
    func overrideServices(
        memoryStoreFactory: ((String) -> MemoryStore)? = nil,
        adapters: [String: any ToolAdapter]? = nil,
        terminalController: TerminalController? = nil,
        guiLauncher: GUIAppLauncher? = nil,
        scannerFactory: ((URL) -> ProjectScanner)? = nil,
        launchAtLoginManager: (any LaunchAtLoginManaging)? = nil,
        logExporter: (any DevHubLogExporting)? = nil,
        pasteboardHelper: (any PasteboardHandling)? = nil,
        keychain: (any KeychainStoring)? = nil
    ) {
        if let memoryStoreFactory { self.memoryStoreFactory = memoryStoreFactory }
        if let adapters { self.adapterOverrides.merge(adapters) { _, new in new } }
        if let terminalController { _replaceTerminalController(terminalController) }
        if let guiLauncher { _replaceGuiLauncher(guiLauncher) }
        if let scannerFactory { self.scannerFactory = scannerFactory }
        if let launchAtLoginManager { self.launchAtLoginManager = launchAtLoginManager }
        if let logExporter { self.logExporter = logExporter }
        if let pasteboardHelper { self.pasteboardHelper = pasteboardHelper }
        if let keychain { self.keychain = keychain }
    }

    /// 测试用：直接重置引导标志（避免污染其他测试）。
    func resetOnboardingForTesting() {
        onboardingCompleted = false
        preferences.removeObject(forKey: Self.onboardingKey)
    }

    private static let onboardingKey = "devhub.onboarding.completed"
    static let disabledDetailTabsKey = "devhub.projectDetail.disabledTabs"
}

enum SessionLaunchError: LocalizedError, Equatable {
    case workingDirectoryMissing(String)
    case adapterUnavailable(String)
    case resumeUnsupported(String)
    case toolNotConfigured(String)
    case toolNotInstalled(String)
    case missingSecret(String)

    var errorDescription: String? {
        switch self {
        case .workingDirectoryMissing(let path):
            return String(localized: "无法继续：工作目录不存在：\(path)")
        case .adapterUnavailable(let tool):
            return String(localized: "无法继续：未找到 \(tool) 的启动适配器。")
        case .resumeUnsupported(let tool):
            return String(localized: "无法继续：\(tool) 不支持恢复指定会话。")
        case .toolNotConfigured(let tool):
            return String(localized: "无法继续：请先在工具设置中启用 \(tool)。")
        case .toolNotInstalled(let tool):
            return String(localized: "无法继续：未检测到 \(tool)，请先安装或修正启动命令。")
        case .missingSecret(let key):
            return String(localized: "无法继续：Keychain 中未找到 \(key) 的值。")
        }
    }
}
