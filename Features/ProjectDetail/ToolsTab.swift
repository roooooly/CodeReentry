import SwiftUI
import SwiftData
import DevHubCore

struct ToolsTab: View {
    let project: Project
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel = ToolsTabViewModel()
    @State private var alertMessage: String?
    @State private var statusMessage: String?
    @State private var pendingInjection: PendingInjection?
    @State private var installTarget: ToolCardState?

    private let columns = [
        GridItem(.adaptive(minimum: 310, maximum: 460), spacing: 12, alignment: .top)
    ]

    private enum InjectionGate: Hashable {
        case blockedSecret
        case staleSummary
        case warnedSecret
        case truncation
        case codexNewTurn
    }

    private struct PendingInjection {
        let tool: Tool
        let plan: InjectionPlan
        var acknowledged: Set<InjectionGate> = []

        var nextGate: InjectionGate? {
            if plan.scanResult == .blocked { return .blockedSecret }
            if (plan.summaryReviewStatus == .outdated || plan.summaryReviewStatus == .unverified),
               !acknowledged.contains(.staleSummary) {
                return .staleSummary
            }
            if plan.scanResult == .warnedButAllowed && !acknowledged.contains(.warnedSecret) {
                return .warnedSecret
            }
            if plan.lengthStatus == .truncated && !acknowledged.contains(.truncation) {
                return .truncation
            }
            if plan.adapterWarning == .codexStartsNewTurn && !acknowledged.contains(.codexNewTurn) {
                return .codexNewTurn
            }
            return nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "TOOLS / PROJECT"))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .tracking(1.4)
                            .foregroundStyle(DevHubTheme.accent)
                        Text(String(localized: "开发工具"))
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(DevHubTheme.ink)
                        Text(String(localized: "直接启动项目，或在发送前检查并附加项目记忆。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !viewModel.cards.isEmpty {
                        Text(String(localized: "\(viewModel.cards.count) 个已绑定工具"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if viewModel.cards.isEmpty {
                    ContentUnavailableView(
                        String(localized: "尚未绑定工具"),
                        systemImage: "wrench.and.screwdriver",
                        description: Text(String(localized: "DevHub 会在项目扫描后列出可用的 CLI 与编辑器。"))
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(viewModel.cards) { card in
                            ToolCard(
                                state: card,
                                onContinueInTerminal: {
                                    Task { await runContinueInTerminal(card.tool) }
                                },
                                onContinueWithMemory: {
                                    Task { await runContinueWithMemory(card.tool) }
                                },
                                onOpenGui: {
                                    Task { await runOpenGui(card.tool) }
                                },
                                onInstall: {
                                    installTarget = card
                                }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .task {
            viewModel.boundProjectPath = project.path
            viewModel.registerAdapterProvider { id in deps.adapter(for: id) }
            viewModel.loadTools(from: deps.modelContainer.mainContext, matching: project)
            await viewModel.refreshInstallStates()
        }
        .alert(String(localized: "启动失败"), isPresented: Binding(get: { alertMessage != nil }, set: { if !$0 { alertMessage = nil } })) {
            Button(String(localized: "好")) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .alert(
            String(localized: "项目记忆已复制"),
            isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )
        ) {
            Button(String(localized: "好")) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
        // codex 二次确认
        .confirmationDialog(
            String(localized: "codex 会立即发起一轮新对话"),
            isPresented: gateBinding(.codexNewTurn),
            titleVisibility: .visible
        ) {
            Button(String(localized: "继续发送")) {
                acknowledge(.codexNewTurn)
            }
            Button(String(localized: "取消"), role: .cancel) { pendingInjection = nil }
        } message: {
            Text(String(localized: "向 codex 发送项目记忆将立即作为一条用户消息发送并开启新对话，不是系统上下文。确认继续？"))
        }
        // 波动性会话总结来源不明或已经落后：允许只发送稳定 context.md。
        .confirmationDialog(
            staleSummaryTitle,
            isPresented: gateBinding(.staleSummary),
            titleVisibility: .visible
        ) {
            Button(String(localized: "只发送稳定上下文")) {
                let tool = pendingInjection?.tool
                pendingInjection = nil
                if let tool { Task { await runContinueWithStableContextOnly(tool) } }
            }
            Button(String(localized: "仍发送这份总结")) {
                acknowledge(.staleSummary)
            }
            Button(String(localized: "取消"), role: .cancel) { pendingInjection = nil }
        } message: {
            Text(staleSummaryMessage)
        }
        // 8KB 截断确认
        .confirmationDialog(
            String(localized: "项目记忆超过 8KB，将被截断"),
            isPresented: gateBinding(.truncation),
            titleVisibility: .visible
        ) {
            Button(String(localized: "截断后发送")) {
                acknowledge(.truncation)
            }
            Button(String(localized: "取消"), role: .cancel) { pendingInjection = nil }
        } message: {
            Text(String(localized: "注入内容超过 8KB，将被截断。完整内容仍可在 .devhub/memory/context.md 查看。"))
        }
        // 文件或剪贴板注入命中敏感内容：不会进入 argv，但仍必须让用户知情确认。
        .confirmationDialog(
            String(localized: "项目记忆包含疑似敏感信息"),
            isPresented: gateBinding(.warnedSecret),
            titleVisibility: .visible
        ) {
            Button(warnedSecretActionTitle) { acknowledge(.warnedSecret) }
            Button(String(localized: "取消"), role: .cancel) { pendingInjection = nil }
        } message: {
            Text(warnedSecretMessage)
        }
        // 命中敏感（位置参数）→ 选择不注入打开 / 取消
        .confirmationDialog(
            String(localized: "检测到疑似敏感信息，已阻止注入"),
            isPresented: gateBinding(.blockedSecret),
            titleVisibility: .visible
        ) {
            Button(String(localized: "不注入打开")) {
                let tool = pendingInjection?.tool
                pendingInjection = nil
                if let tool { Task { await runContinueInTerminal(tool) } }
            }
            Button(String(localized: "取消"), role: .cancel) { pendingInjection = nil }
        } message: {
            Text(String(localized: "渲染后的项目记忆命中疑似敏感信息（如密钥）。位置参数注入会把它暴露在命令行参数中，已阻止。可选择不注入直接打开。"))
        }
        .sheet(item: $installTarget) { card in
            InstallRunnerView(
                viewModel: InstallRunnerViewModel(
                    toolName: card.tool.name,
                    method: card.installMethod,
                    installCommand: card.installCommand,
                    downloadURL: card.downloadURL
                )
            ) {
                Task { await viewModel.refreshInstallStates() }
            }
        }
    }

    // MARK: - 动作流

    @MainActor
    private func runContinueInTerminal(_ tool: Tool) async {
        do {
            _ = try await viewModel.continueInTerminal(for: tool, deps: deps)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runOpenGui(_ tool: Tool) async {
        do {
            try await viewModel.openGuiProject(for: tool, deps: deps)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runContinueWithMemory(_ tool: Tool) async {
        do {
            let plan = try await viewModel.planInject(for: tool, deps: deps)
            pendingInjection = PendingInjection(tool: tool, plan: plan)
            executeIfAllGatesAcknowledged()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runContinueWithStableContextOnly(_ tool: Tool) async {
        do {
            let plan = try await viewModel.planInject(
                for: tool,
                deps: deps,
                includeLastSessionSummary: false
            )
            pendingInjection = PendingInjection(tool: tool, plan: plan)
            executeIfAllGatesAcknowledged()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    @MainActor
    private func proceedInject(_ pending: PendingInjection) async {
        do {
            let outcome = try await viewModel.continueWithMemory(
                for: pending.tool,
                plan: pending.plan,
                deps: deps
            )
            if outcome.copiedMemory {
                statusMessage = String(localized: "DevHub 已复制项目记忆并启动工具，但不会模拟键盘输入。请在目标 CLI 中手动粘贴；若剪贴板内容未变化，30 秒后会自动清理。")
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func gateBinding(_ gate: InjectionGate) -> Binding<Bool> {
        Binding(
            get: { pendingInjection?.nextGate == gate },
            set: { isPresented in
                if !isPresented, pendingInjection?.nextGate == gate {
                    pendingInjection = nil
                }
            }
        )
    }

    private func acknowledge(_ gate: InjectionGate) {
        guard var pending = pendingInjection else { return }
        pending.acknowledged.insert(gate)
        pendingInjection = pending
        executeIfAllGatesAcknowledged()
    }

    private var warnedSecretActionTitle: String {
        if pendingInjection?.plan.effectiveMode == .clipboard {
            return String(localized: "仍复制到剪贴板")
        }
        return String(localized: "仍通过临时文件发送")
    }

    private var warnedSecretMessage: String {
        if pendingInjection?.plan.effectiveMode == .clipboard {
            return String(localized: "检测到疑似密钥或 token。内容会复制到系统剪贴板，之后需要你在目标 CLI 手动粘贴；若期间未复制其他内容，DevHub 会在 30 秒后清理。剪贴板历史工具仍可能保留副本，请确认可以发送。")
        }
        return String(localized: "检测到疑似密钥或 token。内容不会写入命令行参数，但目标 CLI 会读取临时文件。请确认这些内容可以发送给该工具。")
    }

    private var staleSummaryTitle: String {
        if pendingInjection?.plan.summaryReviewStatus == .outdated {
            return String(localized: "会话总结可能已经过期")
        }
        return String(localized: "无法验证会话总结来源")
    }

    private var staleSummaryMessage: String {
        if pendingInjection?.plan.summaryReviewStatus == .outdated {
            return String(localized: "项目中存在更新时间更晚的会话。这份总结可能遗漏后续决定；你可以只发送稳定的 context.md，或确认仍发送旧总结。")
        }
        return String(localized: "这份总结来自旧版本或手工文件，DevHub 无法确认它对应哪次会话。建议只发送稳定的 context.md，或在“会话”页重新生成总结。")
    }

    private func executeIfAllGatesAcknowledged() {
        guard let pending = pendingInjection, pending.nextGate == nil else { return }
        pendingInjection = nil
        Task { await proceedInject(pending) }
    }
}
