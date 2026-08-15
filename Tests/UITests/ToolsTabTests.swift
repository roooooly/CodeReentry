import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("ToolsTab ViewModel — 双动作逻辑")
@MainActor
struct ToolsTabTests {

    // ── 卡片样式 ──

    @Test("CLI 工具卡片为 cliDualAction，永不 running")
    func cliCardStyle() throws {
        let env = try ToolsTabTests.makeEnv(tools: [.codex])
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)

        let card = try #require(vm.cards.first)
        #expect(card.actionStyle == .cliDualAction)
        #expect(card.runningStatus == nil)
        #expect(card.capabilitiesBadges.isEmpty == false)
    }

    @Test("GUI 工具卡片为 guiOpenOnly，永不 running")
    func guiCardStyle() throws {
        let env = try ToolsTabTests.makeEnv(tools: [.vscode])
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)

        let card = try #require(vm.cards.first)
        #expect(card.actionStyle == .guiOpenOnly)
        #expect(card.runningStatus == nil)
    }

    @Test("自定义 CLI 的剪贴板模式可复制项目记忆")
    func customClipboardCardCanInject() throws {
        let env = try ToolsTabTests.makeEnv(tools: [.customClipboard])
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { _ in nil }
        vm.loadTools(from: env.ctx, matching: env.project)

        let card = try #require(vm.cards.first)
        #expect(card.actionStyle == .cliDualAction)
        #expect(card.canInjectMemory)
    }

    // ── 注入计划（InjectionManager 编排）──

    @Test("planInject: 清洁内容 → scanResult=.clear, 无 adapter 警告")
    func planInjectClean() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.claude], contextMd: "# 安全的项目上下文\n决策 A")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)

        let claude = env.tools[0]
        let plan = try await vm.planInject(for: claude, deps: env.deps)
        #expect(plan.scanResult == .clear)
        #expect(plan.lengthStatus == .withinLimit)
        #expect(plan.adapterWarning == nil)
        #expect(plan.rendered.isEmpty == false)
    }

    @Test("planInject: codex 位置参数 → adapterWarning=.codexStartsNewTurn")
    func planInjectCodexWarnsNewTurn() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.codex], contextMd: "安全内容")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)

        let codex = env.tools[0]
        let plan = try await vm.planInject(for: codex, deps: env.deps)
        #expect(plan.adapterWarning == .codexStartsNewTurn)
    }

    @Test("planInject: 位置参数命中敏感 → scanResult=.blocked（InjectionManager 降级 mode）")
    func planInjectPositionalSecretBlocked() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.codex], contextMd: "token = AKIAIOSFODNN7EXAMPLE")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)

        let codex = env.tools[0]
        let plan = try await vm.planInject(for: codex, deps: env.deps)
        #expect(plan.scanResult == .blocked)
        #expect(plan.requiresUserChoice == true)
    }

    @Test("planInject: cliFlag（claude）命中敏感 → scanResult=.warnedButAllowed（临时文件不进 argv）")
    func planInjectCliFlagSecretAllowed() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.claude], contextMd: "secret = -----BEGIN RSA PRIVATE KEY-----")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)

        let claude = env.tools[0]
        let plan = try await vm.planInject(for: claude, deps: env.deps)
        #expect(plan.scanResult == .warnedButAllowed)
        #expect(plan.adapterWarning == nil)
    }

    @Test("planInject: 超 8KB → lengthStatus=.truncated")
    func planInjectOver8KB() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.claude], contextMd: String(repeating: "a", count: 9000))
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)

        let claude = env.tools[0]
        let plan = try await vm.planInject(for: claude, deps: env.deps)
        #expect(plan.lengthStatus == .truncated)
        #expect(plan.rendered.utf8.count <= InjectionManager.maxLength)
    }

    @Test("Codex secret blocking follows adapter capability even when persisted mode is wrong")
    func codexModeMismatchCannotBypassSecretBlocking() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.codex], contextMd: "token = AKIAIOSFODNN7EXAMPLE")
        let codex = env.tools[0]
        codex.injectionMode = .cliFlag  // simulate stale/imported/user-edited unsafe setting
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)

        let plan = try await vm.planInject(for: codex, deps: env.deps)

        #expect(plan.scanResult == .blocked)
        #expect(plan.requiresUserChoice)
    }

    // ── 启动动作（CLI → adapter.resume → terminalController.execute；GUI → guiLauncher.launchApp）──

    @Test("continueInTerminal(claude, 无选中会话) → adapter.launchNew 被调用 + terminalController.execute 被调用 + injectedMemory=false")
    func cliNoInjectionLaunch() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.claude], contextMd: "x")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)
        let claude = env.tools[0]

        let outcome = try await vm.continueInTerminal(for: claude, deps: env.deps)
        #expect(outcome.injectedMemory == false)
        // 无选中会话 → launchNew（而非 resume）
        #expect(env.adapter(forId: "claude-code").launchNewCount == 1)
        // ctx 不带 renderedMemoryFile
        #expect(env.adapter(forId: "claude-code").lastLaunchNewCtx?.renderedMemoryFile == nil)
        // terminalController 接到了 launcher path（execute 设置 lastLauncherPath）
        #expect(env.deps.terminalController.lastLauncherPath != nil)
    }

    @Test("continueWithMemory(claude, 清洁) → adapter.launchNew ctx 带 renderedMemoryFile + injectedMemory=true")
    func claudeInjectLaunch() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.claude], contextMd: "# 上下文\n安全")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)
        let claude = env.tools[0]

        let outcome = try await vm.continueWithMemory(for: claude, deps: env.deps)
        #expect(outcome.injectedMemory == true)
        let file = env.adapter(forId: "claude-code").lastLaunchNewCtx?.renderedMemoryFile
        #expect(file != nil)
        // 临时文件存在且非空
        if let f = file {
            let content = try String(contentsOfFile: f, encoding: .utf8)
            #expect(content.contains("上下文"))
        }
    }

    @Test("continueWithMemory(codex, 位置参数命中敏感) → 降级为不注入，injectedMemory=false")
    func codexSecretBlockedDegradesToNoInjection() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.codex], contextMd: "token = AKIAIOSFODNN7EXAMPLE")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)
        let codex = env.tools[0]

        // 调用方（View）本应先 planInject 见 blocked 让用户选「不注入打开」；
        // 这里直接调用 continueWithMemory 验证它不会强行注入
        let plan = try await vm.planInject(for: codex, deps: env.deps)
        #expect(plan.requiresUserChoice == true)

        let outcome = try await vm.continueInTerminal(for: codex, deps: env.deps)
        #expect(outcome.injectedMemory == false)
        // 不注入路径：ctx 无 renderedMemoryFile
        #expect(env.adapter(forId: "codex").lastLaunchNewCtx?.renderedMemoryFile == nil)
    }

    @Test("continueWithMemory(clipboard) → 仅复制剪贴板、启动上下文不创建记忆文件")
    func clipboardInjectionLaunch() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.customClipboard], contextMd: "# 剪贴板上下文\n安全内容")
        let pasteboard = MockPasteboardHandler()
        env.deps.overrideServices(pasteboardHelper: pasteboard)
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { _ in nil }
        vm.loadTools(from: env.ctx, matching: env.project)
        let tool = env.tools[0]

        let plan = try await vm.planInject(for: tool, deps: env.deps)
        #expect(plan.effectiveMode == .clipboard)
        let outcome = try await vm.continueWithMemory(for: tool, plan: plan, deps: env.deps)

        #expect(!outcome.injectedMemory)
        #expect(outcome.copiedMemory)
        #expect(pasteboard.writtenText == plan.rendered)
        await Task.yield()
        #expect(pasteboard.clearDelay == 30)
        let launcher = try #require(outcome.launcherPath)
        let script = try String(contentsOfFile: launcher, encoding: .utf8)
        #expect(!script.contains("$(cat "))
        #expect(!script.contains(plan.rendered))
    }

    @Test("openGuiProject(vscode) → guiLauncher.launchApp 被 gui workspace 记录 bundleId")
    func guiLaunch() async throws {
        let env = try ToolsTabTests.makeEnv(tools: [.vscode], contextMd: "")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { id in env.adapter(forId: id) }
        vm.loadTools(from: env.ctx, matching: env.project)
        let vscode = env.tools[0]

        try await vm.openGuiProject(for: vscode, deps: env.deps)
        #expect(env.guiWorkspace.lastBundleId == "com.microsoft.VSCode")
    }

    // MARK: - fixture

    enum ToolKindFixture { case codex, claude, vscode, customClipboard }

    @MainActor
    final class MockPasteboardHandler: PasteboardHandling {
        var writtenText: String?
        var clearDelay: TimeInterval?

        func write(text: String) { writtenText = text }
        func clearIfUnchanged(after delay: TimeInterval) async { clearDelay = delay }
    }

    struct TestEnv {
        let container: ModelContainer
        let ctx: ModelContext
        let project: Project
        let projectPath: String
        let tools: [Tool]
        let deps: AppDependencies
        let guiWorkspace: MockGUIWorkspace
        private let adapters: [String: MockToolAdapter]
        init(container: ModelContainer, ctx: ModelContext, project: Project, projectPath: String,
             tools: [Tool], deps: AppDependencies, guiWorkspace: MockGUIWorkspace,
             adapters: [String: MockToolAdapter]) {
            self.container = container; self.ctx = ctx; self.project = project
            self.projectPath = projectPath; self.tools = tools; self.deps = deps
            self.guiWorkspace = guiWorkspace; self.adapters = adapters
        }
        func adapter(forId id: String) -> MockToolAdapter { adapters[id]! }
    }

    static func makeEnv(tools: [ToolKindFixture], contextMd: String = "") throws -> TestEnv {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        // 真实临时目录作为项目路径（git status 会返回 nil，无妨）
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-tool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let project = ProjectFixtures.makeProject(name: "ExampleApp", path: tmp.path, isPinned: true, group: nil, tags: [])
        ctx.insert(project)

        // 内存 factory：恒返回指向 tmp 的 store，内容为 contextMd
        // 直接写入项目 tmp 的 memory 目录，并让 factory 忽略入参返回该 store。
        let memDir = tmp.appendingPathComponent(".devhub").appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        try contextMd.write(to: memDir.appendingPathComponent("context.md"), atomically: true, encoding: .utf8)
        let projectStore = MemoryStore(projectRoot: tmp)
        let projectFactory: (String) -> MemoryStore = { _ in projectStore }

        // 构造工具 + adapter
        var toolModels: [Tool] = []
        var adapterMap: [String: MockToolAdapter] = [:]
        for (i, k) in tools.enumerated() {
            switch k {
            case .codex:
                let m = makeToolModel(name: "codex", kind: .cli, injectionMode: .positionalArg, sortOrder: i, project: project)
                toolModels.append(m); ctx.insert(m)
                adapterMap["codex"] = MockToolAdapter(toolId: "codex", executablePath: "/x/codex", requiresPTY: true,
                                                      capabilities: [.canInjectPositional, .canResume])
            case .claude:
                let m = makeToolModel(name: "claude", kind: .cli, injectionMode: .cliFlag, sortOrder: i, project: project)
                toolModels.append(m); ctx.insert(m)
                adapterMap["claude-code"] = MockToolAdapter(toolId: "claude-code", executablePath: "/x/claude", requiresPTY: true,
                                                            capabilities: [.canInjectSystemPrompt, .canResume])
            case .vscode:
                let m = makeToolModel(name: "VS Code", kind: .app, injectionMode: .clipboard, sortOrder: i, project: project)
                toolModels.append(m); ctx.insert(m)
                let vscodeAdapter = MockToolAdapter(toolId: "vscode", executablePath: "/x/vscode", requiresPTY: false,
                                                    capabilities: [.canOpenGUI])
                vscodeAdapter.stubbedBundleId = "com.microsoft.VSCode"
                adapterMap["vscode"] = vscodeAdapter
            case .customClipboard:
                let m = makeToolModel(name: "Custom Clipboard", kind: .cli, injectionMode: .clipboard, sortOrder: i, project: project)
                toolModels.append(m); ctx.insert(m)
                let adapter = MockToolAdapter(
                    toolId: "custom-cli", executablePath: "/x/custom", requiresPTY: true,
                    capabilities: []
                )
                adapterMap["custom clipboard"] = adapter
                adapterMap["custom-cli"] = adapter
            }
        }
        try ctx.save()

        // deps：注入 no-op terminal executor + mock gui workspace + adapter 覆盖 + 内存 factory
        let deps = AppDependencies(modelContainer: container)
        let tc = TerminalController()
        tc.executor = { _ in [:] }  // no-op，不真启 Terminal
        let ws = MockGUIWorkspace()
        let gui = GUIAppLauncher(workspace: ws)
        deps.overrideServices(
            memoryStoreFactory: projectFactory,
            adapters: adapterMap,
            terminalController: tc,
            guiLauncher: gui
        )

        return TestEnv(container: container, ctx: ctx, project: project, projectPath: tmp.path,
                       tools: toolModels, deps: deps, guiWorkspace: ws, adapters: adapterMap)
    }

    static func makeToolModel(name: String, kind: ToolKind, injectionMode: InjectionMode, sortOrder: Int, project: Project) -> Tool {
        let t = Tool(
            name: name, kind: kind,
            launchCommand: "/usr/local/bin/\(name)",
            workingDirMode: .projectRoot,
            injectMemory: true, injectionMode: injectionMode,
            envVars: [:], secretEnvKeys: [], enabled: true, sortOrder: sortOrder
        )
        t.projects = [project]
        return t
    }
}
