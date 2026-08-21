import SwiftUI
import DevHubCore

struct ReentryEvidenceView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var showingCompletion = false
    @State private var showingCancelConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var localErrorMessage: String?

    private let columns = [
        GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 12)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                heading
                if let error = localErrorMessage ?? deps.reentryTrials.errorMessage {
                    errorCard(error)
                }
                activeMeasurement
                if deps.reentryTrials.summary.attemptCount > 0 {
                    summarySection
                    gateSection
                    if !deps.reentryTrials.summary.failureCounts.isEmpty {
                        failureSection
                    }
                } else {
                    firstMeasurementGuide
                }
                privacySection
            }
            .padding(24)
            .frame(maxWidth: 1050, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .task { await deps.reentryTrials.refresh() }
        .sheet(isPresented: $showingCompletion) {
            ReentryTrialCompletionView(coordinator: deps.reentryTrials)
        }
        .confirmationDialog(
            String(localized: "放弃这次测量？"),
            isPresented: $showingCancelConfirmation
        ) {
            Button(String(localized: "放弃测量"), role: .destructive) {
                deps.reentryTrials.cancelActive()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "未完成的计时只存在于内存中，放弃后不会写入任何记录。"))
        }
        .confirmationDialog(
            String(localized: "删除全部本地恢复记录？"),
            isPresented: $showingDeleteConfirmation
        ) {
            Button(String(localized: "永久删除全部记录"), role: .destructive) {
                Task { await deleteAllEvidence() }
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "这会删除已记录的 CSV 和未完成的计时，无法撤销；项目、会话和源文件不会受到影响。"))
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("RECOVERY / EVIDENCE")
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(DevHubTheme.accent)
            Text(String(localized: "你的恢复是否真的更快？"))
                .font(.largeTitle.bold())
            Text(String(localized: "用真实工作测量恢复速度与正确性。只有你主动开始和提交时才会记录，结果始终留在本机。"))
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var activeMeasurement: some View {
        if let trial = deps.reentryTrials.activeTrial {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label(
                            deps.reentryTrials.capturedElapsedSeconds == nil
                                ? String(localized: "正在测量恢复")
                                : String(localized: "恢复耗时已冻结"),
                            systemImage: "stopwatch.fill"
                        )
                            .font(.headline)
                            .foregroundStyle(DevHubTheme.accent)
                        Text(
                            deps.reentryTrials.capturedElapsedSeconds == nil
                                ? String(localized: "在原工具确认项目、会话和上下文后，回到这里记录结果。")
                                : String(localized: "填写结果表单的时间不会计入恢复耗时。")
                        )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(duration(deps.reentryTrials.elapsedSeconds(at: context.date)))
                            .font(.system(.title, design: .monospaced).weight(.semibold))
                            .contentTransition(.numericText())
                    }
                }
                HStack(spacing: 16) {
                    Label(trial.tool.displayName, systemImage: "terminal")
                    Label(trial.projectSlot, systemImage: "number")
                    Label(trial.sessionAge.displayName, systemImage: "calendar")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Button {
                        do {
                            try deps.reentryTrials.captureElapsed()
                            localErrorMessage = nil
                            showingCompletion = true
                        } catch {
                            localErrorMessage = error.localizedDescription
                        }
                    } label: {
                        Label(String(localized: "记录恢复结果"), systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    Button(String(localized: "放弃本次测量"), role: .destructive) {
                        showingCancelConfirmation = true
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(18)
            .background(DevHubTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(DevHubTheme.accent.opacity(0.35), lineWidth: 1)
            }
        } else {
            HStack(spacing: 14) {
                Image(systemName: "stopwatch")
                    .font(.title2)
                    .foregroundStyle(DevHubTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(String(localized: "没有正在进行的测量"))
                        .font(.headline)
                    Text(String(localized: "打开一个项目的会话详情，点击“测量这次恢复”。CodeReentry 会启动计时并继续到原工具。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "本地结果"))
                .font(.title2.bold())
            LazyVGrid(columns: columns, spacing: 12) {
                metricCard(
                    value: "\(deps.reentryTrials.summary.attemptCount)",
                    label: String(localized: "真实尝试"),
                    detail: String(localized: "跨 \(deps.reentryTrials.summary.recordedSpanDays) 天")
                )
                metricCard(
                    value: "\(deps.reentryTrials.summary.correctPercent)%",
                    label: String(localized: "正确恢复"),
                    detail: String(localized: "\(deps.reentryTrials.summary.correctCount) 次项目与会话都正确")
                )
                metricCard(
                    value: secondsValue(deps.reentryTrials.summary.medianReentrySeconds),
                    label: String(localized: "恢复中位数"),
                    detail: String(localized: "从点击到确认上下文")
                )
                metricCard(
                    value: percentValue(deps.reentryTrials.summary.relativeImprovementPercent),
                    label: String(localized: "相对手动方式"),
                    detail: String(localized: "正数表示更快")
                )
            }
        }
    }

    private var gateSection: some View {
        let summary = deps.reentryTrials.summary
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "证据门槛"))
                    .font(.title2.bold())
                Spacer()
                Label(
                    summary.targetsMet
                        ? String(localized: "目标已满足")
                        : summary.coverageMet
                            ? String(localized: "覆盖已满足，目标未满足")
                            : String(localized: "继续收集真实尝试"),
                    systemImage: summary.targetsMet
                        ? "checkmark.seal.fill"
                        : "circle.dotted"
                )
                .font(.callout.weight(.semibold))
                .foregroundStyle(summary.targetsMet ? .green : .secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 9) {
                gateRow(String(localized: "至少 10 次"), met: summary.attemptCount >= 10)
                gateRow(String(localized: "至少 7 天"), met: summary.recordedSpanDays >= 7)
                gateRow(String(localized: "至少 3 个匿名项目"), met: summary.projectCount >= 3)
                gateRow(String(localized: "至少 2 种工具"), met: summary.toolCount >= 2)
                gateRow(String(localized: "包含近期会话"), met: summary.recentCount > 0)
                gateRow(String(localized: "包含较早会话"), met: summary.olderCount > 0)
            }
            Text(String(localized: "目标：正确率 ≥90%，恢复中位数 ≤60 秒，相对提升 ≥50%，重复背景减少 ≥70%，且无跨项目上下文事故。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private var failureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "失败分布"))
                .font(.headline)
            ForEach(
                deps.reentryTrials.summary.failureCounts.sorted { $0.key.rawValue < $1.key.rawValue },
                id: \.key
            ) { failure, count in
                HStack {
                    Text(failure.displayName)
                    Spacer()
                    Text("\(count)").monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(16)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var firstMeasurementGuide: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(String(localized: "完成第一次真实测量"))
                .font(.headline)
            Text(String(localized: "1. 先估算不用 CodeReentry 时，手动找回项目、会话和背景需要多少秒。"))
            Text(String(localized: "2. 在项目的“会话”页查看对话，然后点“测量这次恢复”。"))
            Text(String(localized: "3. 在原工具确认恢复结果，回来提交正确性与粗粒度背景减少比例。"))
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
    }

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(String(localized: "只留本机，不含工作内容"), systemImage: "lock.shield.fill")
                .font(.headline)
            Text(String(localized: "记录仅包含匿名项目槽、工具、会话新旧、秒数、结果和粗粒度失败分类；不记录项目名、路径、会话 ID、提示词、消息或备注，也没有上传功能。"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("~/Library/Application Support/CodeReentry/reentry-trials.csv")
                .font(.caption.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if deps.reentryTrials.hasStoredEvidence
                || deps.reentryTrials.activeTrial != nil {
                Divider().padding(.vertical, 2)
                Button(String(localized: "删除全部本地记录…"), role: .destructive) {
                    showingDeleteConfirmation = true
                }
                .buttonStyle(.borderless)
                .help(String(localized: "删除恢复证据 CSV 和未完成的计时"))
            }
        }
        .padding(16)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorCard(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metricCard(value: String, label: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(value).font(.title.bold()).monospacedDigit()
            Text(label).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 105, alignment: .leading)
        .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.5)) }
    }

    private func gateRow(_ title: String, met: Bool) -> some View {
        Label(title, systemImage: met ? "checkmark.circle.fill" : "circle")
            .font(.callout)
            .foregroundStyle(met ? .green : .secondary)
    }

    private func duration(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func secondsValue(_ value: Int?) -> String {
        value.map { "\($0)s" } ?? "—"
    }

    private func percentValue(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "—"
    }

    @MainActor
    private func deleteAllEvidence() async {
        do {
            try await deps.reentryTrials.deleteAllEvidence()
            localErrorMessage = nil
        } catch {
            localErrorMessage = error.localizedDescription
        }
    }
}

private struct ReentryTrialCompletionView: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: ReentryTrialCoordinator

    @State private var baseline = "120"
    @State private var outcome: ReentryTrialOutcome = .correct
    @State private var reduction: ReentryTrialReductionBand = .high
    @State private var crossProject = false
    @State private var failure: ReentryTrialFailure = .none
    @State private var validationMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "记录恢复结果"))
                    .font(.title2.bold())
                Text(String(localized: "请按实际结果填写；这份记录只保存在本机。"))
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField(String(localized: "手动恢复基线（秒）"), text: $baseline)
                    .textFieldStyle(.roundedBorder)

                Picker(String(localized: "恢复结果"), selection: $outcome) {
                    ForEach(ReentryTrialOutcome.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }

                Picker(String(localized: "重复背景减少比例"), selection: $reduction) {
                    ForEach(ReentryTrialReductionBand.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }

                if outcome != .correct {
                    Picker(String(localized: "失败分类"), selection: $failure) {
                        ForEach(ReentryTrialFailure.allCases.filter { $0 != .none }, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    Toggle(String(localized: "出现了跨项目上下文"), isOn: $crossProject)
                }
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Text(String(localized: "已冻结恢复耗时：\(coordinator.elapsedSeconds()) 秒"))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "取消")) { dismiss() }
                Button(String(localized: "保存本地记录")) {
                    Task { await save() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: outcome) { _, newValue in
            if newValue == .correct {
                failure = .none
                crossProject = false
            } else if failure == .none {
                failure = .other
            }
        }
    }

    @MainActor
    private func save() async {
        guard let baselineSeconds = Int(baseline), baselineSeconds > 0 else {
            validationMessage = String(localized: "请输入大于 0 的手动恢复秒数。")
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await coordinator.complete(
                baselineSeconds: baselineSeconds,
                outcome: outcome,
                reductionBand: reduction,
                crossProjectContext: outcome == .correct ? false : crossProject,
                failure: outcome == .correct ? .none : failure
            )
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}

private extension ReentryTrialTool {
    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .zcode: "ZCode"
        case .opencode: "OpenCode"
        case .kimi: "Kimi"
        case .geminiCLI: "Gemini CLI"
        case .githubCopilot: "GitHub Copilot CLI"
        case .aider: "Aider"
        }
    }
}

private extension ReentryTrialSessionAge {
    var displayName: String {
        switch self {
        case .recent: String(localized: "近期会话（7 天内）")
        case .older: String(localized: "较早会话（7 天前）")
        }
    }
}

private extension ReentryTrialOutcome {
    var displayName: String {
        switch self {
        case .correct: String(localized: "项目、会话和上下文都正确")
        case .wrongProject: String(localized: "打开了错误项目")
        case .wrongSession: String(localized: "打开了错误会话")
        case .unusableContext: String(localized: "上下文无法继续工作")
        case .launchFailed: String(localized: "原工具启动失败")
        }
    }
}

private extension ReentryTrialReductionBand {
    var displayName: String {
        switch self {
        case .zero: String(localized: "0%（没有减少）")
        case .low: "1–29%"
        case .medium: "30–69%"
        case .high: "70–99%"
        case .complete: String(localized: "100%（无需重复）")
        }
    }
}

private extension ReentryTrialFailure {
    var displayName: String {
        switch self {
        case .none: String(localized: "无")
        case .pathMissing: String(localized: "项目路径缺失")
        case .sessionNotFound: String(localized: "未找到会话")
        case .readerUnsupported: String(localized: "正文读取不支持")
        case .resumeUnsupported: String(localized: "指定会话恢复不支持")
        case .wrongBinding: String(localized: "项目绑定错误")
        case .staleSummary: String(localized: "会话总结过期")
        case .toolLaunch: String(localized: "工具启动失败")
        case .other: String(localized: "其他")
        }
    }
}
