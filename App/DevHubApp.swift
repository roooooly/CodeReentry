import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import DevHubCore

@MainActor
final class DevHubApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdown: (() async -> Void)?
    private var isShuttingDown = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown else { return .terminateNow }
        guard !isShuttingDown else { return .terminateLater }
        isShuttingDown = true
        Task { @MainActor [weak self, weak sender] in
            await shutdown()
            self?.shutdown = nil
            sender?.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct DevHubApp: App {
    static let mainWindowID = "devhub-main"

    @NSApplicationDelegateAdaptor(DevHubApplicationDelegate.self) private var appDelegate
    @State private var dependencies: AppDependencies
    @State private var showOnboarding: Bool
    @State private var menuBarController: MenuBarController?
    @State private var mainWindowPresenter: MainWindowPresenter
    @State private var showingImportDialog = false
    @State private var appearanceTheme: String
    @State private var startupWarning: String?
    @State private var sparkleUpdater: SparkleUpdater?
    private let demoWorkspace: DemoWorkspace?

    init() {
        let runtimeMode = AppRuntimeMode.resolve(arguments: ProcessInfo.processInfo.arguments)
        let demoWorkspace = runtimeMode == .demo ? try? DemoWorkspace() : nil
        let startup = DevHubApp.makeModelContainer(runtimeMode: runtimeMode)
        let container = startup.container
        let preferences = demoWorkspace?.preferences ?? .standard
        let deps = AppDependencies(
            modelContainer: container,
            preferences: preferences,
            runtimeMode: runtimeMode,
            sessionReaders: demoWorkspace?.sessionReaders
        )
        var warning = startup.warning
        if runtimeMode == .demo {
            do {
                guard let demoWorkspace else { throw DemoWorkspaceError.preferencesUnavailable }
                try demoWorkspace.seed(into: container)
                deps.onboardingCompleted = true
            } catch {
                warning = String(localized: "演示工作区无法初始化：\(error.localizedDescription)")
            }
        }
        let settings = try? deps.ensureAppSettings(in: container.mainContext)
        // Bundle localization is chosen before the first window is rendered.
        // UserDefaults is the fast bootstrap path; an imported SwiftData
        // preference is used when no bootstrap preference exists yet.
        let bootstrapLanguage = preferences.string(
            forKey: AppLanguage.preferenceKey
        ).map(AppLanguage.resolved)
            ?? AppLanguage.resolved(settings?.locale)
        AppLanguage.apply(bootstrapLanguage, to: preferences)
        _dependencies = State(initialValue: deps)
        _showOnboarding = State(initialValue: runtimeMode == .standard && !deps.onboardingCompleted)
        _mainWindowPresenter = State(initialValue: MainWindowPresenter())
        let theme = settings?.theme ?? "system"
        _appearanceTheme = State(initialValue: theme)
        _startupWarning = State(initialValue: warning)
        _sparkleUpdater = State(initialValue: nil)
        self.demoWorkspace = demoWorkspace
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            Group {
                if showOnboarding {
                    OnboardingView(
                        dependencies: dependencies,
                        onComplete: { showOnboarding = false }
                    )
                } else {
                    ContentView(mainWindowPresenter: mainWindowPresenter)
                        .environment(dependencies)
                        .modelContainer(dependencies.modelContainer)
                        .onAppear { installMenuBarIfNeeded() }
                        .sheet(isPresented: $showingImportDialog) {
                            BackupImportView(dependencies: dependencies, isPresented: $showingImportDialog)
                        }
                        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DevHubImportBackup"))) { _ in
                            showingImportDialog = true
                        }
                }
            }
            .preferredColorScheme(Self.colorScheme(for: appearanceTheme))
            .onReceive(NotificationCenter.default.publisher(
                for: Notification.Name("DevHubAppearanceChanged")
            )) { note in
                if let theme = note.object as? String { appearanceTheme = theme }
            }
            .alert(String(localized: "CodeReentry 数据存储提示"),
                   isPresented: Binding(get: { startupWarning != nil }, set: { if !$0 { startupWarning = nil } })) {
                Button(String(localized: "好")) { startupWarning = nil }
            } message: {
                Text(startupWarning ?? "")
            }
        }
        .defaultSize(width: 1200, height: 800)
        .commands { commandsBody }

        Settings {
            if dependencies.isDemoMode {
                DemoModeSettingsView()
            } else {
                SettingsView()
                    .environment(dependencies)
                    .modelContainer(dependencies.modelContainer)
            }
        }
    }

    private static func colorScheme(for theme: String) -> ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var commandsBody: some Commands {
        CommandGroup(replacing: .importExport) {
            if dependencies.isDemoMode {
                Text(String(localized: "演示模式不导入或导出真实数据"))
            } else {
                Button(String(localized: "导出备份…")) {
                    Task { await Self.exportBackup(dependencies: dependencies) }
                }
                Button(String(localized: "导入备份…")) {
                    NotificationCenter.default.post(name: Notification.Name("DevHubImportBackup"), object: nil)
                }
            }
        }
    }

    /// 导出备份到用户选择的路径（NSSavePanel）。
    private static func exportBackup(dependencies: AppDependencies) async {
        let exporter = DataExporter(modelContainer: dependencies.modelContainer)
        do {
            let doc = try await exporter.export()
            let name = exporter.fileName(for: Date())
            let panel = NSSavePanel()
            panel.title = String(localized: "导出 CodeReentry 备份")
            panel.message = String(localized: "备份包含项目配置与索引，但不会包含 Keychain 中的密钥值；在新设备导入后需要重新录入密钥。")
            panel.nameFieldStringValue = name
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let data = try BackupDocumentCodec.encode(doc)
            try data.write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "导出备份失败")
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
    static func makeModelContainer(
        runtimeMode: AppRuntimeMode = .standard
    ) -> (container: ModelContainer, warning: String?) {
        if runtimeMode == .demo {
            do {
                return (try ModelContainerFactory.makeContainer(inMemory: true), nil)
            } catch {
                fatalError("无法创建演示用内存 ModelContainer: \(error)")
            }
        }
        do {
            let result = try ModelContainerFactory.makeRecoveringContainer()
            let warning = result.recoveredStoreDirectory.map {
                String(localized: "原数据库无法打开，已保留到 \($0.path)，并创建了一个新数据库。你可以从 CodeReentry 备份重新导入数据。")
            }
            return (result.container, warning)
        } catch {
            do {
                let memory = try ModelContainerFactory.makeContainer(inMemory: true)
                return (
                    memory,
                    String(localized: "持久数据库无法打开（\(error.localizedDescription)）。本次将使用临时内存数据库，退出后更改不会保存；请先导出诊断信息并修复磁盘权限。")
                )
            } catch {
                fatalError("无法创建持久或内存 ModelContainer: \(error)")
            }
        }
    }

    /// 安装菜单栏图标（首次 onAppear 时）。
    private func installMenuBarIfNeeded() {
        guard menuBarController == nil else { return }
        if dependencies.isDemoMode {
            let workspace = demoWorkspace
            appDelegate.shutdown = {
                workspace?.cleanup()
            }
            return
        }
        let shutdownDependencies = dependencies
        appDelegate.shutdown = { [weak shutdownDependencies] in
            await shutdownDependencies?.mcpSupervisor.stopAll()
        }
        let container = dependencies.modelContainer
        let vm = MenuBarViewModel(topN: 5) {
            // 从主 ModelContext 按 lastOpenedAt 降序取前 5
            let ctx = container.mainContext
            var desc = FetchDescriptor<Project>(
                sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
            )
            desc.fetchLimit = 5
            let projects = (try? ctx.fetch(desc)) ?? []
            return projects.compactMap {
                guard let opened = $0.lastOpenedAt else { return nil }
                _ = opened
                return MenuBarItem(id: $0.id, name: $0.name, path: $0.path, stableId: $0.stableId)
            }
        }
        let controller = MenuBarController(viewModel: vm)
        controller.onShowApp = { [weak mainWindowPresenter] in
            mainWindowPresenter?.show()
        }
        controller.onSelectProject = { stableId in
            dependencies.selectedProjectStableId = stableId
            do {
                if try MenuBarProjectSelectionRecorder.markOpened(
                    stableId: stableId,
                    modelContext: container.mainContext
                ) {
                    NotificationCenter.default.post(
                        name: MenuBarController.projectsChangedNotification,
                        object: nil
                    )
                }
            } catch {
                NSLog("[menubar] 更新最近项目失败: %@", error.localizedDescription)
            }
        }
        controller.install()
        menuBarController = controller
        Task { await dependencies.mcpSupervisor.startAll() }
        Task { await startSparkleIfNeeded() }
        // 会话索引与历史用量都可能横跨数十 GB。启动阶段只加载已经持久化的
        // SwiftData 索引；用户进入相应页面或点击刷新时才做受限的增量扫描。
        // 资源管理器空闲时不应仅为刷新辅助信息而持续占用 CPU/内存。
    }

    /// 启动 Sparkle 自动更新（§8.3）。feedURL 未配置时静默跳过。
    @MainActor
    private func startSparkleIfNeeded() async {
        let config = SparkleUpdaterConfig()
        guard config.feedURL != nil else { return }
        guard let driver = try? SparkleProductionDriver() else {
            NSLog("Sparkle driver 初始化失败，跳过自动更新")
            return
        }
        let updater = SparkleUpdater(driver: driver, config: config)
        sparkleUpdater = updater
        await updater.setAutomaticallyChecksUpdates(true, interval: 86400)
    }
}

/// Keeps the menu-bar entry connected to the SwiftUI scene after every main window closes.
/// A live window is focused in place; otherwise the stored `openWindow` action creates one.
@MainActor
final class MainWindowPresenter {
    private weak var window: NSWindow?
    private var openWindow: (() -> Void)?

    func register(openWindow: @escaping () -> Void) {
        self.openWindow = openWindow
    }

    func register(window: NSWindow, openWindow: @escaping () -> Void) {
        self.window = window
        register(openWindow: openWindow)
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct DemoModeSettingsView: View {
    var body: some View {
        ContentUnavailableView {
            Label(String(localized: "演示工作区"), systemImage: "shield.lefthalf.filled")
        } description: {
            Text(String(localized: "演示模式只使用合成项目和会话，退出后自动清除；不会读取本机会话、启动外部工具或写入正式数据库。"))
        }
        .frame(width: 520, height: 320)
    }
}

struct DemoModeBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "shield.lefthalf.filled")
            Text(String(localized: "演示模式 · 纯合成数据"))
                .font(.callout.weight(.semibold))
            Text(String(localized: "退出后数据自动清除，不读取本机会话，也不会启动外部工具。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("./scripts/run-source.sh")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .foregroundStyle(DevHubTheme.ink)
        .background(DevHubTheme.gold.opacity(0.16))
        .overlay(alignment: .bottom) {
            Divider().overlay(DevHubTheme.gold.opacity(0.45))
        }
        .accessibilityElement(children: .combine)
    }
}

private final class MainWindowObservingView: NSView {
    var onWindowChange: ((NSWindow) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindowChange?(window) }
    }
}

private struct MainWindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> MainWindowObservingView {
        let view = MainWindowObservingView()
        view.onWindowChange = onResolve
        return view
    }

    func updateNSView(_ nsView: MainWindowObservingView, context: Context) {
        nsView.onWindowChange = onResolve
        if let window = nsView.window { onResolve(window) }
    }
}

/// 根容器：sidebar + detail。
struct ContentView: View {
    let mainWindowPresenter: MainWindowPresenter

    @Environment(AppDependencies.self) private var deps
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @State private var showCommandPalette = false
    /// 已确认插件的 action（异步从 store 加载，⌘P 触发时通常已就绪）。
    @State private var pluginCommandItems: [CommandItem] = []
    /// 已连接 MCP server 的 ToolContribution 与运行时元数据。
    @State private var mcpCommandItems: [CommandItem] = []
    @State private var mcpToolInfos: [MCPToolInfo] = []
    @State private var queuedMCPTool: MCPToolInfo?
    @State private var pendingMCPTool: MCPToolInfo?
    /// 执行门控失败时提示用户。
    @State private var pluginAlert: String?
    @State private var mcpAlert: String?

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            if let stableId = deps.selectedProjectStableId {
                ProjectDetailView(projectStableId: stableId)
            } else if let destination = deps.selectedGlobalDestination {
                GlobalDestinationView(destination: destination)
            } else {
                ContentUnavailableView(
                    String(localized: "选择一个项目或全局视图"),
                    systemImage: "square.grid.2x2",
                    description: Text(String(localized: "也可以拖入文件夹来注册新项目。"))
                )
            }
        }
        .tint(DevHubTheme.accent)
        .safeAreaInset(edge: .top, spacing: 0) {
            if deps.isDemoMode {
                DemoModeBanner()
            }
        }
        .background {
            MainWindowAccessor { window in
                mainWindowPresenter.register(window: window) {
                    openWindow(id: DevHubApp.mainWindowID)
                }
            }
        }
        .sheet(isPresented: $showCommandPalette, onDismiss: {
            if let tool = queuedMCPTool {
                queuedMCPTool = nil
                pendingMCPTool = tool
            }
        }) {
            CommandPaletteView(
                viewModel: CommandPaletteViewModel(allItems: commandItems(), onExecute: handleCommand),
                onCancel: { showCommandPalette = false }
            )
        }
        .sheet(item: $pendingMCPTool) { tool in
            MCPToolRunnerSheet(tool: tool, caller: deps.mcpSupervisor)
        }
        .alert(String(localized: "插件操作结果"),
               isPresented: Binding(get: { pluginAlert != nil }, set: { if !$0 { pluginAlert = nil } })) {
            Button(String(localized: "好")) { pluginAlert = nil }
        } message: {
            Text(pluginAlert ?? "")
        }
        .alert(String(localized: "MCP 工具不可用"),
               isPresented: Binding(get: { mcpAlert != nil }, set: { if !$0 { mcpAlert = nil } })) {
            Button(String(localized: "好")) { mcpAlert = nil }
        } message: {
            Text(mcpAlert ?? "")
        }
        .task {
            if !deps.isDemoMode {
                await loadPluginCommandItems()
                await loadMCPCommandItems()
            }
        }
        .task {
            if !deps.isDemoMode {
                await PerformanceScenarioRunner.runIfRequested(
                    dependencies: deps,
                    modelContext: modelContext
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: PluginEnableViewModel.commandsChangedNotification
        )) { _ in
            Task { await loadPluginCommandItems() }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: MCPClientSupervisor.toolsChangedNotification
        )) { _ in
            Task { await loadMCPCommandItems() }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DevHubShowCommandPalette"))) { _ in
            showCommandPalette = true
        }
        .background(Button(action: { showCommandPalette = true }) {
            Text("").hidden()
        }
        .keyboardShortcut("p", modifiers: .command)
        .accessibilityHidden(true))
    }

    /// ⌘P 命令面板命令源：项目 + 标签 + 已确认 Rail C action + 已连接 MCP 工具。
    private func commandItems() -> [CommandItem] {
        var items: [CommandItem] = []
        if let projects = try? modelContext.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)])) {
            items.append(contentsOf: projects.map { .openProject(name: $0.name, stableId: $0.stableId) })
        }
        items.append(contentsOf: CommandItem.enabledDetailTabItems(deps.enabledDetailTabs))
        // Rail C 插件 actions：只列已确认的（§6.4 安全门控）
        items.append(contentsOf: pluginCommandItems)
        items.append(contentsOf: mcpCommandItems)
        return items
    }

    /// 异步加载已确认插件的 action 到缓存（命令面板列表用）。
    private func loadPluginCommandItems() async {
        guard !deps.isDemoMode else {
            pluginCommandItems = []
            return
        }
        let registry = ScriptPluginRegistry(root: ScriptPluginRegistry.defaultRoot)
        var items: [CommandItem] = []
        for ref in registry.allActions() {
            let confirmed = await deps.pluginPermissionStore.isConfirmed(pluginId: ref.pluginId)
            guard confirmed else { continue }
            items.append(.runPluginAction(name: ref.action.title, pluginId: ref.pluginId, actionId: ref.action.id))
        }
        pluginCommandItems = items
    }

    /// ToolContribution is the launcher contract; MCPToolInfo supplies the
    /// schema and exact server/tool identity needed by the execution sheet.
    private func loadMCPCommandItems() async {
        guard !deps.isDemoMode else {
            mcpCommandItems = []
            mcpToolInfos = []
            return
        }
        let contributions = await deps.mcpSupervisor.allContributions().tools
        let toolInfos = await deps.mcpSupervisor.allToolInfos()
        mcpToolInfos = toolInfos
        mcpCommandItems = MCPCommandCatalog.items(
            contributions: contributions,
            toolInfos: toolInfos
        )
    }

    private func handleCommand(_ item: CommandItem) {
        switch item {
        case .openProject(_, let stableId):
            deps.selectedProjectStableId = stableId
        case .switchTab(_, let tab):
            NotificationCenter.default.post(name: Notification.Name("DevHubSwitchTab"), object: tab)
        case .runPluginAction(_, let pluginId, let actionId):
            // 执行门控：用带 store 的 runner，查 manifest 权限，前置校验。
            let registry = ScriptPluginRegistry(root: ScriptPluginRegistry.defaultRoot)
            let store = deps.pluginPermissionStore
            Task {
                guard let plugin = registry.scan().first(where: { $0.id == pluginId }),
                      let action = plugin.manifest.contributions.actions.first(where: { $0.id == actionId }) else {
                    pluginAlert = String(localized: "插件或动作已不存在，请在设置中重新扫描插件。")
                    return
                }
                let ref = ScriptPluginActionRef(
                    pluginId: pluginId,
                    pluginDir: plugin.dir,
                    action: action,
                    minAppVersion: plugin.manifest.minAppVersion
                )
                let runner = ScriptPluginRunner(permissionStore: store)
                do {
                    let ctx = try ScriptPluginActionContextResolver.context(
                        selectedProjectStableId: deps.selectedProjectStableId,
                        selectedSessionId: deps.selectedSessionId,
                        modelContext: modelContext
                    )
                    let result = try await runner.run(action: ref, context: ctx,
                                                      pluginId: pluginId,
                                                      requiredPermissions: plugin.manifest.permissions)
                    let message = ScriptPluginActionFeedback.resultMessage(
                        actionTitle: action.title,
                        result: result
                    )
                    if !result.succeeded {
                        NSLog("%@", ScriptPluginActionFeedback.auditSummary(
                            actionId: actionId,
                            result: result
                        ))
                    }
                    pluginAlert = message
                } catch ScriptPluginError.notConfirmed {
                    pluginAlert = String(localized: "此插件尚未启用。请到设置 → 插件中确认权限后重试。")
                } catch {
                    // actionId 与错误文本都可能包含 manifest 内容、脚本路径或项目路径。
                    // 用户仍能在当前弹窗看到可操作错误；长期日志只记录事件类型。
                    NSLog("[plugin] action execution threw an error")
                    pluginAlert = error.localizedDescription
                }
            }
        case .runMCPTool(_, let serverName, let toolName):
            guard let tool = mcpToolInfos.first(where: {
                $0.serverName == serverName && $0.name == toolName
            }) else {
                mcpAlert = String(localized: "该工具已从 MCP server 的最新工具列表中移除。请重新打开命令面板。")
                showCommandPalette = false
                return
            }
            // Queue it for the palette's onDismiss callback so AppKit never has
            // to transition between two sheets in the same presentation pass.
            queuedMCPTool = tool
        }
        showCommandPalette = false
    }
}
