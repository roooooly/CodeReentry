import SwiftUI
import AppKit
import DevHubCore

struct OnboardingView: View {
    let dependencies: AppDependencies
    let onComplete: () -> Void

    @State private var flow: OnboardingFlow

    init(
        dependencies: AppDependencies,
        onComplete: @escaping () -> Void,
        flow: OnboardingFlow = OnboardingFlow()
    ) {
        self.dependencies = dependencies
        self.onComplete = onComplete
        _flow = State(initialValue: flow)
    }

    var body: some View {
        ZStack {
            DevHubPaperBackground()
            VStack(spacing: 0) {
                onboardingProgress
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                Divider()
                Group {
                    switch flow.step {
                    case .welcome:     welcomeStep
                    case .pickRoot:    pickRootStep
                    case .scanning:    scanningStep
                    case .confirm:     confirmStep
                    case .intro:       introStep
                    case .permissions: permissionsStep
                    }
                }
                .padding(32)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(width: 720, height: 540)
            .background(DevHubTheme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(DevHubTheme.divider, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.07), radius: 24, y: 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(DevHubTheme.accent)
    }

    private var onboardingProgress: some View {
        let titles = [
            String(localized: "欢迎"),
            String(localized: "扫描项目"),
            String(localized: "权限"),
            String(localized: "开始使用")
        ]
        return HStack(spacing: 10) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(index <= progressIndex ? Color.accentColor : Color.secondary.opacity(0.18))
                        if index < progressIndex {
                            Image(systemName: "checkmark")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(index == progressIndex ? .white : .secondary)
                        }
                    }
                    .frame(width: 22, height: 22)
                    Text(title)
                        .font(.caption.weight(index == progressIndex ? .semibold : .regular))
                        .foregroundStyle(index == progressIndex ? .primary : .secondary)
                }
                if index < 3 {
                    Rectangle()
                        .fill(index < progressIndex ? Color.accentColor.opacity(0.55) : Color.secondary.opacity(0.15))
                        .frame(maxWidth: .infinity, maxHeight: 1)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "首次设置进度"))
    }

    private var progressIndex: Int {
        switch flow.step {
        case .welcome: return 0
        case .pickRoot, .scanning, .confirm: return 1
        case .permissions: return 2
        case .intro: return 3
        }
    }

    // Step: 欢迎
    private var welcomeStep: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 22) {
                Image(systemName: "circle.grid.hex.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(DevHubTheme.accent)
                    .frame(width: 74, height: 74)
                    .background(DevHubTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "DEVHUB / LOCAL WORKSPACE"))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .tracking(1.6)
                        .foregroundStyle(DevHubTheme.accent)
                    Text(String(localized: "欢迎使用 DevHub"))
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(DevHubTheme.ink)
                    Text(String(localized: "一个以项目为核心的本地开发资源管理器。把工具、会话、记忆、订阅与发布账号放回同一个工作上下文。"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                welcomeBenefit(icon: "arrow.uturn.forward", title: String(localized: "更快继续工作"), detail: String(localized: "从项目或最近会话直接回到原工具"))
                welcomeBenefit(icon: "lock.shield", title: String(localized: "默认本地、只读"), detail: String(localized: "会话留在磁盘；DevHub 只建立轻量索引"))
                welcomeBenefit(icon: "gauge.with.dots.needle.50percent", title: String(localized: "按需扫描"), detail: String(localized: "不用时不在后台反复读取历史记录"))
            }
            .padding(18)
            .background(DevHubTheme.subtleFill.opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(DevHubTheme.divider, lineWidth: 1)
            }
            HStack {
                Label(String(localized: "全部设置均可稍后修改"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(String(localized: "开始设置")) { flow.goToPickRoot() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityHint(String(localized: "进入项目根目录选择"))
            }
        }
    }

    private func welcomeBenefit(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(DevHubTheme.accent)
                .frame(width: 24)
            Text(title)
                .font(.callout.weight(.semibold))
                .frame(width: 112, alignment: .leading)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // Step: 选项目根目录
    private var pickRootStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(String(localized: "选择项目根目录"))
                    .font(.title2.bold())
                Text(String(localized: "只扫描一层候选目录并读取仓库/包清单；确认前不会注册任何项目。"))
                    .foregroundStyle(.secondary)
            }
            HStack {
                TextField(String(localized: "项目根目录"), text: $flow.projectsRoot)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "选择…")) { pickFolder() }
            }
            VStack(alignment: .leading, spacing: 10) {
                Label(String(localized: "识别 Git、package.json、Cargo.toml、go.mod 与 pyproject.toml"), systemImage: "checkmark.circle")
                Label(String(localized: "源代码与会话原文件不会被修改"), systemImage: "checkmark.circle")
                Label(String(localized: "稍后仍可从侧边栏拖入单个项目"), systemImage: "checkmark.circle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DevHubTheme.subtleFill.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button(String(localized: "返回")) { flow.goToWelcome() }
                Spacer()
                Button(String(localized: "扫描")) {
                    Task { await flow.scan(deps: dependencies) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // Step: 扫描中
    private var scanningStep: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text(String(localized: "正在扫描项目候选..."))
                .foregroundStyle(.secondary)
        }
    }

    // Step: 确认注册
    private var confirmStep: some View {
        VStack(spacing: 12) {
            Text(String(localized: "确认要注册的项目"))
                .font(.title2.bold())
            if let err = flow.scanError {
                Text(err).foregroundStyle(.red)
            }
            if flow.candidates.isEmpty {
                ContentUnavailableView {
                    Label(String(localized: "未发现候选项目"), systemImage: "folder.badge.questionmark")
                } description: {
                    Text(String(localized: "你可以返回选择其他目录，也可以先跳过，稍后从侧边栏添加项目。"))
                }
                .frame(maxHeight: 300)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(flow.candidates) { c in
                            Toggle(isOn: Binding(
                                get: { flow.selectedCandidates.contains(c.path) },
                                set: { newVal in
                                    if newVal { flow.selectedCandidates.insert(c.path) }
                                    else { flow.selectedCandidates.remove(c.path) }
                                }
                            )) {
                                HStack {
                                    Text(c.name)
                                    if c.hasGit {
                                        Image(systemName: "circle.lefthalf.filled")
                                            .foregroundStyle(.green)
                                    }
                                    Text(c.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .accessibilityLabel(String(localized: "注册 \(c.name)"))
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            HStack {
                Button(String(localized: "返回")) { flow.step = .pickRoot }
                Spacer()
                Button(flow.selectedCandidates.isEmpty
                       ? String(localized: "跳过并继续")
                       : String(localized: "注册选中并继续")) {
                    do { try flow.confirmRegistration(deps: dependencies) }
                    catch { flow.scanError = error.localizedDescription }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // Step: 权限请求
    private var permissionsStep: some View {
        VStack(spacing: 16) {
            Text(String(localized: "系统权限说明"))
                .font(.title2.bold())
            if let summary = flow.registrationSummary {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: summary.hasSkippedCandidates
                          ? "exclamationmark.triangle.fill"
                          : "checkmark.circle.fill")
                        .foregroundStyle(summary.hasSkippedCandidates ? Color.orange : DevHubTheme.green)
                    Text(summary.message)
                        .font(.caption)
                        .foregroundStyle(DevHubTheme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DevHubTheme.subtleFill.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(DevHubTheme.divider, lineWidth: 1)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    icon: "bell.badge",
                    title: String(localized: "通知"),
                    desc: String(localized: "首次启用订阅提醒时请求。拒绝则无提醒，其余功能不受影响。")
                )
                permissionRow(
                    icon: "applescript",
                    title: String(localized: "AppleScript Automation"),
                    desc: String(localized: "首次启动 CLI 工具时请求控制 Terminal/iTerm。拒绝则该功能不可用。"))
                permissionRow(
                    icon: "lock.shield",
                    title: String(localized: "文件访问 (TCC)"),
                    desc: String(localized: "读取 ~/.claude/ 等点目录通常无需授权。仅当项目位于 ~/Desktop / ~/Documents / ~/Downloads 时才触发。若被拒，请到「系统设置 → 隐私与安全性 → 完全磁盘访问」手动添加 DevHub。"))
            }
            Spacer()
            Button(String(localized: "继续")) { flow.goToIntro() }
                .buttonStyle(.borderedProminent)
        }
    }

    // Step: 首次会话价值路径
    private var introStep: some View {
        VStack(spacing: 16) {
            Text(String(localized: "找回第一条会话"))
                .font(.title2.bold())
            Text(String(localized: "项目已就绪。最后由你主动触发一次只读增量扫描，DevHub 才能把本地会话关联到项目。"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                introRow(
                    icon: "tray.and.arrow.down",
                    title: String(localized: "扫描本地会话"),
                    desc: String(localized: "只读取受支持工具的有界元数据，不在后台运行")
                )
                introRow(
                    icon: "arrow.uturn.forward.circle",
                    title: String(localized: "从项目继续"),
                    desc: String(localized: "首页显示最近可恢复会话，一步回到原工具")
                )
                introRow(
                    icon: "brain.head.profile",
                    title: String(localized: "保留项目记忆"),
                    desc: String(localized: "需要时再把经确认的会话总结写入 context.md")
                )
            }
            Spacer()
            if let error = flow.sessionScanError {
                Text(
                    String(
                        format: String(localized: "会话扫描未完成：%@"),
                        locale: .current,
                        error
                    )
                )
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(String(localized: "暂不扫描")) {
                    flow.complete(deps: dependencies, onComplete: onComplete)
                }
                .disabled(flow.isScanningSessions)
                Spacer()
                Button {
                    Task {
                        await flow.scanSessionsAndComplete(
                            deps: dependencies,
                            operation: { try await dependencies.runAggregation() },
                            onComplete: onComplete
                        )
                    }
                } label: {
                    HStack(spacing: 8) {
                        if flow.isScanningSessions {
                            ProgressView().controlSize(.small)
                        }
                        Text(
                            flow.isScanningSessions
                                ? String(localized: "正在扫描本地会话…")
                                : String(localized: "扫描会话并开始")
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(flow.isScanningSessions)
                .accessibilityHint(
                    String(localized: "仅在点击后增量读取本机会话元数据，不在后台扫描")
                )
            }
        }
    }

    private func permissionRow(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func introRow(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.tint)
            Text(title).font(.body.weight(.semibold)).frame(width: 150, alignment: .leading)
            Text(desc).foregroundStyle(.secondary)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            flow.projectsRoot = url.path
        }
    }
}
