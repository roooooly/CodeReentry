import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

/// 端到端集成：用**真实** ClaudeAdapter / CodexAdapter（非 mock）跑 ToolsTabViewModel，
/// 校验 Core LauncherScriptBuilder 生成的 0700 launcher script 内容与权限。
/// 这覆盖 spec §5.2 / §10 的关键安全测试：记忆内容不进 argv 字面、占位展开为 $(cat)。
@Suite("Launcher 集成 — 注册 → 启动 → 校验脚本")
@MainActor
struct LauncherIntegrationTests {

    @Test("claude continueWithMemory → launcher 含 --append-system-prompt-file，0700")
    func claudeLauncherContent() async throws {
        let env = try LauncherIntegrationTests.makeEnv(toolName: "claude", injectionMode: .cliFlag,
                                                       adapterId: "claude-code", adapter: ClaudeAdapter(),
                                                       contextMd: "# 项目上下文\n决策 A")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { _ in env.adapterRef }
        vm.loadTools(from: env.ctx, matching: env.project)

        let outcome = try await vm.continueWithMemory(for: env.tool, deps: env.deps)
        #expect(outcome.injectedMemory == true)
        #expect(outcome.launcherPath != nil)

        // 校验生成的 launcher script（Core TerminalController.lastLauncherPath）
        guard let path = outcome.launcherPath else {
            Issue.record("launcher path 为空"); return
        }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("--append-system-prompt-file"))
        #expect(content.contains("cd "))  // 切到项目目录
        // Claude 用 flag + 文件路径（非 $(cat) 展开模式）；记忆内容绝不进 argv 字面
        #expect(content.contains("决策 A") == false)
        #expect(content.contains("$(cat ") == false)  // claude 是 cliFlag，不是 positional

        // 权限 0700
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        #expect((perm & 0o777) == 0o700)
    }

    @Test("codex continueWithMemory → launcher 含 resume + \"$(cat ...)\"，且 plan 有 codexStartsNewTurn 警告")
    func codexLauncherContent() async throws {
        let env = try LauncherIntegrationTests.makeEnv(toolName: "codex", injectionMode: .positionalArg,
                                                       adapterId: "codex", adapter: CodexAdapter(),
                                                       contextMd: "安全内容")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { _ in env.adapterRef }
        vm.loadTools(from: env.ctx, matching: env.project)

        let plan = try await vm.planInject(for: env.tool, deps: env.deps)
        #expect(plan.adapterWarning == .codexStartsNewTurn)
        #expect(plan.scanResult == .clear)

        let outcome = try await vm.continueWithMemory(for: env.tool, deps: env.deps)
        #expect(outcome.injectedMemory == true)
        guard let path = outcome.launcherPath else { Issue.record("launcher path 为空"); return }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        // codex 位置参数：launcher 里记忆走 "$(cat '<file>')"，不进字面
        #expect(content.contains("$(cat ") == true)
        #expect(content.contains("安全内容") == false)
        // 0700
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perm = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        #expect((perm & 0o777) == 0o700)
    }

    @Test("codex 位置参数命中敏感 → 阻止注入；选不注入打开 → launcher 无 PROMPT/cat")
    func codexSecretBlocked() async throws {
        let env = try LauncherIntegrationTests.makeEnv(toolName: "codex", injectionMode: .positionalArg,
                                                       adapterId: "codex", adapter: CodexAdapter(),
                                                       contextMd: "token = AKIAIOSFODNN7EXAMPLE")
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { _ in env.adapterRef }
        vm.loadTools(from: env.ctx, matching: env.project)

        let plan = try await vm.planInject(for: env.tool, deps: env.deps)
        #expect(plan.scanResult == .blocked)

        // 模拟用户选「不注入打开」
        let outcome = try await vm.continueInTerminal(for: env.tool, deps: env.deps)
        #expect(outcome.injectedMemory == false)
        guard let path = outcome.launcherPath else { Issue.record("launcher path 为空"); return }
        let content = try String(contentsOfFile: path, encoding: .utf8)
        // 不注入 → 不应有 $(cat ...) 记忆引用
        #expect(content.contains("$(cat ") == false)
    }

    @Test("GUI 工具 → guiLauncher.launchApp 调用，bundleId 正确（VSCodeAdapter）")
    func guiLaunchIntegration() async throws {
        let env = try LauncherIntegrationTests.makeEnv(toolName: "VS Code", injectionMode: .clipboard,
                                                       adapterId: "vscode", adapter: VSCodeAdapter(),
                                                       contextMd: "", isGui: true)
        let vm = ToolsTabViewModel()
        vm.boundProjectPath = env.projectPath
        vm.registerAdapterProvider { _ in env.adapterRef }
        vm.loadTools(from: env.ctx, matching: env.project)

        try await vm.openGuiProject(for: env.tool, deps: env.deps)
        #expect(env.guiWorkspace.lastBundleId == "com.microsoft.VSCode")
    }

    // MARK: - env

    struct LauncherEnv {
        let container: ModelContainer
        let ctx: ModelContext
        let project: Project
        let projectPath: String
        let tool: Tool
        let deps: AppDependencies
        let guiWorkspace: MockGUIWorkspace
        let adapterRef: any ToolAdapter
    }

    static func makeEnv(toolName: String, injectionMode: InjectionMode, adapterId: String,
                        adapter: any ToolAdapter, contextMd: String, isGui: Bool = false) throws -> LauncherEnv {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let project = ProjectFixtures.makeProject(name: "ExampleApp", path: tmp.path, isPinned: true, group: nil, tags: [])
        ctx.insert(project)

        // 写项目记忆到 tmp/.devhub/memory/context.md
        let memDir = tmp.appendingPathComponent(".devhub").appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        try contextMd.write(to: memDir.appendingPathComponent("context.md"), atomically: true, encoding: .utf8)
        let projectStore = MemoryStore(projectRoot: tmp)

        let tool = Tool(name: toolName, kind: isGui ? .app : .cli,
                        launchCommand: "/usr/local/bin/\(toolName)",
                        workingDirMode: .projectRoot,
                        injectMemory: true, injectionMode: injectionMode,
                        enabled: true, sortOrder: 0)
        tool.projects = [project]
        ctx.insert(tool)
        try ctx.save()

        let deps = AppDependencies(modelContainer: container)
        let tc = TerminalController()
        tc.executor = { _ in [:] }  // 不真启 Terminal
        let ws = MockGUIWorkspace()
        let gui = GUIAppLauncher(workspace: ws)
        deps.overrideServices(
            memoryStoreFactory: { _ in projectStore },
            adapters: [adapterId: adapter],
            terminalController: tc,
            guiLauncher: gui
        )

        return LauncherEnv(container: container, ctx: ctx, project: project, projectPath: tmp.path,
                           tool: tool, deps: deps, guiWorkspace: ws, adapterRef: adapter)
    }
}
