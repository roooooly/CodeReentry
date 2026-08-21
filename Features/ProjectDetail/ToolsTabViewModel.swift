import Foundation
import SwiftData
import OSLog
import DevHubCore

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "tools-tab")

/// 敏感扫描结果（UI 呈现用）
enum SecretScanOutcome: Equatable, Sendable {
    case clear
    case blocked            // 位置参数命中 → Core 降级 mode；UI 阻止注入，提供「不注入打开」
    case warnedButAllowed   // cliFlag 命中（临时文件不进 argv）→ 允许，仅提示
}

/// 渲染长度状态
enum LengthStatus: Equatable, Sendable {
    case withinLimit
    case truncated
}

/// codex 注入的额外警告（spec §5.2 关键）
enum AdapterSpecificWarning: Equatable, Sendable {
    case codexStartsNewTurn  // "会立即发起一轮对话"
}

/// 注入计划（决定 UI 如何呈现确认弹窗）
struct InjectionPlan: Sendable {
    let rendered: String
    let effectiveMode: InjectionMode
    let scanResult: SecretScanOutcome
    let lengthStatus: LengthStatus
    let summaryReviewStatus: SessionSummaryReviewStatus
    let adapterWarning: AdapterSpecificWarning?
    /// scanResult == .blocked 时为 true → UI 弹「不注入打开 / 取消」
    let requiresUserChoice: Bool
}

/// 启动动作结果
struct LaunchOutcome: Sendable {
    let injectedMemory: Bool
    let copiedMemory: Bool
    let launcherPath: String?
}

/// 单张卡片视图模型
struct ToolCardState: Identifiable {
    let id: UUID
    let tool: Tool
    let adapter: (any ToolAdapter)?
    let actionStyle: ActionStyle
    let canInjectMemory: Bool
    let usesClipboard: Bool
    /// P0 永远为 nil（方案 B 外部终端 + GUI 均不追踪 PID）
    let runningStatus: String? = nil
    let capabilitiesBadges: [String]
    /// 安装状态（§工具管理 三态）。
    var installState: ToolInstallState = .checking
    /// adapter 提供的安装方式（用于"一键安装"按钮）。
    let installMethod: InstallMethod
    let installCommand: String?
    let downloadURL: String?

    enum ActionStyle { case cliDualAction, guiOpenOnly }
}

enum ToolsTabError: Error, LocalizedError {
    case adapterUnavailable(String)
    case launchFailed(String)
    var errorDescription: String? {
        switch self {
        case .adapterUnavailable(let name): return String(localized: "工具 \(name) 的 adapter 不可用")
        case .launchFailed(let msg):       return String(localized: "启动失败：\(msg)")
        }
    }
}

@Observable
@MainActor
final class ToolsTabViewModel {
    var cards: [ToolCardState] = []
    /// 当前项目路径（由 View 在 .task 中注入）
    var boundProjectPath: String?
    /// 只用于判断波动性会话总结是否落后于最新索引，不影响稳定 context.md。
    var latestProjectSessionAt: Date?

    /// adapter 解析 provider（由 View 注入 deps.adapter(for:)）。
    private var adapterProvider: (String) -> (any ToolAdapter)? = { _ in nil }
    func registerAdapterProvider(_ p: @escaping (String) -> (any ToolAdapter)?) {
        adapterProvider = p
    }

    // MARK: - 加载卡片

    func loadTools(from ctx: ModelContext, matching project: Project) {
        latestProjectSessionAt = project.sessions.map(\.updatedAt).max()
        let targetId = project.id
        let descriptor = FetchDescriptor<Tool>(
            predicate: #Predicate { $0.enabled && $0.projects.contains(where: { $0.id == targetId }) },
            sortBy: [SortDescriptor(\.sortOrder)]
        )
        let tools = (try? ctx.fetch(descriptor)) ?? []
        cards = tools.map { makeCard($0) }
    }

    /// 刷新所有卡片的安装状态（探测 + 取版本）。异步、并发、互不阻塞 UI。
    func refreshInstallStates() async {
        let detector = ToolDetector()
        await withTaskGroup(of: (UUID, ToolInstallState).self) { group in
            for index in cards.indices {
                let card = cards[index]
                let cardId = card.id
                let exe = card.adapter?.executablePath
                let detect = card.tool.detectPath
                let launch = card.tool.launchCommand
                let versionArgs = card.adapter?.versionArguments ?? ["--version"]
                group.addTask { @Sendable in
                    let probe = detector.probe(
                        executableHint: exe, detectPath: detect, launchCommand: launch
                    )
                    guard case .found(let path) = probe else {
                        return (cardId, ToolInstallState.notInstalled)
                    }
                    let version = await Self.readVersion(executable: path, args: versionArgs)
                    return (cardId, ToolInstallState.installed(version: version))
                }
            }
            for await (id, state) in group {
                if let idx = cards.firstIndex(where: { $0.id == id }) {
                    cards[idx].installState = state
                }
            }
        }
    }

    /// 跑 `<exe> --version` 取版本号（best-effort，失败返回 nil）。
    private static func readVersion(executable: String, args: [String]) async -> String? {
        let runner = LocalProcessRunner()
        let cfg = LocalProcessRunner.LaunchConfig(
            workingDir: FileManager.default.temporaryDirectory,
            executable: executable, arguments: args, timeout: 8
        )
        guard let lines = try? await runner.runToCompletion(cfg: cfg) else { return nil }
        let combined = lines
            .filter { $0.stream != .system }
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 取第一行非空作为版本串
        return combined.split(separator: "\n").first.map(String.init) ?? (combined.isEmpty ? nil : combined)
    }

    private func makeCard(_ tool: Tool) -> ToolCardState {
        let adapter = adapterLookup(tool)
        let style: ToolCardState.ActionStyle
        var badges: [String]
        if adapter?.requiresPTY == true {
            style = .cliDualAction
            badges = capabilityBadges(adapter?.capabilities ?? [])
        } else {
            style = .guiOpenOnly
            badges = []
        }
        let supportsInjection = adapter?.capabilities.contains(.canInjectSystemPrompt) == true
            || adapter?.capabilities.contains(.canInjectPositional) == true
            || (adapter?.toolId == "custom-cli" && tool.injectionMode == .clipboard)
        let usesClipboard = adapter?.toolId == "custom-cli" && tool.injectionMode == .clipboard
        if usesClipboard {
            badges.append(String(localized: "剪贴板注入"))
        }
        return ToolCardState(
            id: tool.id, tool: tool, adapter: adapter,
            actionStyle: style, canInjectMemory: tool.injectMemory && supportsInjection,
            usesClipboard: usesClipboard,
            capabilitiesBadges: badges,
            installMethod: effectiveInstallMethod(adapter: adapter, tool: tool),
            installCommand: tool.installCommand ?? adapter?.installCommand,
            downloadURL: tool.downloadURL ?? adapter?.downloadURL
        )
    }

    /// 安装方式：Tool 显式值优先，否则回退 adapter 默认。
    private func effectiveInstallMethod(adapter: (any ToolAdapter)?, tool: Tool) -> InstallMethod {
        if let raw = tool.installMethodRaw, let m = InstallMethod(rawValue: raw) { return m }
        return adapter?.installMethod ?? .manual
    }

    private func adapterLookup(_ tool: Tool) -> (any ToolAdapter)? {
        // name → adapter toolId（"claude" → "claude-code"、"VS Code" → "vscode"）
        let byId = toolId(for: tool)
        if let builtIn = adapterProvider(byId) ?? adapterProvider(tool.name.lowercased()) {
            return builtIn
        }
        switch tool.kind {
        case .cli:
            return GenericCLIAdapter(
                injectionMode: tool.injectMemory ? tool.injectionMode : nil,
                injectionArguments: tool.injectionArgs
            )
        case .app:
            return GenericGUIAdapter(configuredIdentifier: tool.launchCommand)
        case .mcp:
            return nil
        }
    }

    private func toolId(for tool: Tool) -> String {
        ToolIdentifierResolver.identifier(for: tool)
    }

    private func capabilityBadges(_ caps: ToolCapabilities) -> [String] {
        var b: [String] = []
        if caps.contains(.canInjectSystemPrompt) { b.append(String(localized: "系统提示注入")) }
        if caps.contains(.canInjectPositional)   { b.append(String(localized: "位置参数注入")) }
        if caps.contains(.canResume)             { b.append(String(localized: "可恢复会话")) }
        if caps.contains(.canOpenGUI)            { b.append("GUI") }
        return b
    }

    // MARK: - 注入计划（复用 Core InjectionManager 的 render→scan→fallback→cap 编排）

    func planInject(
        for tool: Tool,
        deps: AppDependencies,
        includeLastSessionSummary: Bool = true
    ) async throws -> InjectionPlan {
        let path = boundProjectPath ?? tool.projects.first?.path ?? ""
        let adapter = try requireAdapter(tool)
        let store = deps.memoryStore(forProjectPath: path)
        let context = (try? store.readContext()) ?? ""
        let summary = includeLastSessionSummary
            ? ((try? store.readLastSessionSummary()) ?? nil)
            : nil
        let summaryMetadata = includeLastSessionSummary
            ? ((try? store.readLastSessionSummaryMetadata()) ?? nil)
            : nil
        let summaryReviewStatus = SessionSummaryReviewStatus.classify(
            summary: summary,
            metadata: summaryMetadata,
            latestIndexedSessionAt: latestProjectSessionAt
        )
        let gitStatus = try? await deps.gitStatusProvider.status(at: URL(fileURLWithPath: path))

        // 安全策略必须由 adapter 的真实能力决定，不能信任设置页中可编辑的
        // `tool.injectionMode`。否则把 Codex 改成 cliFlag 后，实际 adapter 仍会把
        // 内容放进位置参数，却能绕过 positional secret 阻断。
        let actualMode: InjectionMode
        if adapter.capabilities.contains(.canInjectSystemPrompt) {
            actualMode = .cliFlag
        } else if adapter.capabilities.contains(.canInjectPositional) {
            actualMode = .positionalArg
        } else {
            actualMode = .clipboard
        }
        let prep = InjectionManager.prepare(
            context: context,
            lastSessionSummary: summary,
            gitStatus: gitStatus,
            preferredMode: actualMode,
            allowCliFlagFallback: adapter.capabilities.contains(.canInjectSystemPrompt)
        )

        // 扫描结果映射
        let scanResult: SecretScanOutcome
        if prep.scannedSecrets.isEmpty {
            scanResult = .clear
        } else if prep.fellBackFromPositional {
            // Core 把位置参数降级了 → 对用户呈现为「阻止注入，可降级为不注入打开」
            scanResult = .blocked
        } else {
            // cliFlag 命中秘密但未降级（临时文件不进 argv）→ 允许，仅提示
            scanResult = .warnedButAllowed
        }

        // adapter 特定警告：codex 维持位置参数 → 会立即发起新一轮
        let adapterWarning: AdapterSpecificWarning? = {
            if actualMode == .positionalArg,
               prep.fellBackFromPositional == false,
               adapterLookup(tool)?.toolId == "codex" {
                return .codexStartsNewTurn
            }
            return nil
        }()

        return InjectionPlan(
            rendered: prep.rendered,
            effectiveMode: prep.mode,
            scanResult: scanResult,
            lengthStatus: prep.truncated ? .truncated : .withinLimit,
            summaryReviewStatus: summaryReviewStatus,
            adapterWarning: adapterWarning,
            requiresUserChoice: scanResult == .blocked
        )
    }

    // MARK: - 三个动作

    /// 动作 1：在 Terminal 中启动（不注入）。会话恢复由 Sessions tab 的具体会话行负责。
    func continueInTerminal(for tool: Tool, deps: AppDependencies) async throws -> LaunchOutcome {
        let adapter = try requireAdapter(tool)
        let path = try effectiveWorkingDirectory(for: tool)
        let sessionId: String? = nil
        let ctx = LaunchContext(
            projectPath: path, renderedMemoryFile: nil, sessionId: sessionId, tool: tool,
            environment: try launchEnvironment(for: tool, deps: deps)
        )

        let instance = try await (sessionId == nil
            ? adapter.launchNew(ctx: ctx)
            : adapter.resume(sessionId: sessionId!, ctx: ctx))
        try await dispatch(instance: instance, deps: deps)
        logger.info("CLI 不注入启动 tool=\(tool.name, privacy: .public)")
        return LaunchOutcome(
            injectedMemory: false,
            copiedMemory: false,
            launcherPath: deps.terminalController.lastLauncherPath
        )
    }

    /// 动作 2：启动并发送项目记忆（注入）。调用方应先 planInject 处理 blocked/truncation/warning。
    func continueWithMemory(for tool: Tool, deps: AppDependencies) async throws -> LaunchOutcome {
        let plan = try await planInject(for: tool, deps: deps)
        return try await continueWithMemory(for: tool, plan: plan, deps: deps)
    }

    /// 使用 UI 已向用户展示并确认过的同一份计划执行，避免多重确认后重新计算并绕过后续 gate。
    func continueWithMemory(for tool: Tool, plan: InjectionPlan, deps: AppDependencies) async throws -> LaunchOutcome {
        // 阻止注入：不得强行注入。兜底降级为不注入（调用方应已引导用户选「不注入打开」）。
        if plan.scanResult == .blocked {
            return try await continueInTerminal(for: tool, deps: deps)
        }
        let adapter = try requireAdapter(tool)
        let path = try effectiveWorkingDirectory(for: tool)
        let file: String?
        if plan.effectiveMode == .clipboard {
            file = nil
            let pasteboard = deps.pasteboardHelper
            pasteboard.write(text: plan.rendered)
            Task { await pasteboard.clearIfUnchanged(after: 30) }
        } else {
            file = try deps.writeInjectionFile(plan.rendered)
        }
        let sessionId: String? = nil
        let ctx = LaunchContext(
            projectPath: path, renderedMemoryFile: file, sessionId: sessionId, tool: tool,
            environment: try launchEnvironment(for: tool, deps: deps)
        )

        let instance = try await (sessionId == nil
            ? adapter.launchNew(ctx: ctx)
            : adapter.resume(sessionId: sessionId!, ctx: ctx))
        try await dispatch(instance: instance, deps: deps)
        let copied = plan.effectiveMode == .clipboard
        if copied {
            logger.info("CLI 已复制记忆并启动（需用户手动粘贴）tool=\(tool.name, privacy: .public)")
        } else {
            logger.info("CLI 注入启动 tool=\(tool.name, privacy: .public) mode=\(String(describing: plan.effectiveMode), privacy: .public)")
        }
        return LaunchOutcome(
            injectedMemory: !copied,
            copiedMemory: copied,
            launcherPath: deps.terminalController.lastLauncherPath
        )
    }

    /// GUI 工具动作：打开项目
    func openGuiProject(for tool: Tool, deps: AppDependencies) async throws {
        let adapter = try requireAdapter(tool)
        let path = try effectiveWorkingDirectory(for: tool)
        let instance = try await adapter.launchNew(ctx: LaunchContext(projectPath: path, renderedMemoryFile: nil, sessionId: nil, tool: tool))
        if case .gui(let bundleId) = instance {
            try await deps.guiLauncher.launchApp(bundleId: bundleId, projectPath: path)
        }
    }

    // MARK: - 辅助

    private func dispatch(instance: ToolInstance, deps: AppDependencies) async throws {
        switch instance {
        case .cli(let launcherPath):
            // 通过 AppleScript 在 Terminal 中执行 launcher（0700）。executor 注入点使测试不真启 Terminal。
            _ = try await deps.terminalController.execute(terminal: .terminal, launcherPath: launcherPath)
        case .gui:
            // GUI 工具走 openGuiProject 路径；此处不应到达
            break
        }
    }

    private func requireAdapter(_ tool: Tool) throws -> any ToolAdapter {
        guard let a = adapterLookup(tool) else {
            throw ToolsTabError.adapterUnavailable(tool.name)
        }
        return a
    }

    private func effectiveWorkingDirectory(for tool: Tool) throws -> String {
        let projectPath = boundProjectPath ?? tool.projects.first?.path ?? ""
        let selected: String
        if tool.workingDirMode == .custom,
           let custom = tool.customWorkingDir?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            selected = (custom as NSString).expandingTildeInPath
        } else {
            selected = projectPath
        }
        var isDirectory: ObjCBool = false
        guard !selected.isEmpty,
              FileManager.default.fileExists(atPath: selected, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ToolsTabError.launchFailed(String(localized: "工作目录不存在：\(selected)"))
        }
        return (selected as NSString).standardizingPath
    }

    private func launchEnvironment(for tool: Tool, deps: AppDependencies) throws -> [String: String] {
        var environment = tool.envVars
        for key in tool.secretEnvKeys {
            guard let value = try deps.keychain.get(toolId: tool.id.uuidString, envKey: key) else {
                throw ToolsTabError.launchFailed(String(localized: "Keychain 中未找到 \(key) 的值"))
            }
            environment[key] = value
        }
        return environment
    }

}
