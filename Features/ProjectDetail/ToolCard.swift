import SwiftUI
import DevHubCore

struct ToolCard: View {
    let state: ToolCardState
    let onContinueInTerminal: () -> Void
    let onContinueWithMemory: () -> Void
    let onOpenGui: () -> Void
    var onInstall: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.tool.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DevHubTheme.ink)
                    Text(state.tool.launchCommand)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !state.capabilitiesBadges.isEmpty {
                        capabilityBadges
                    }
                }
                Spacer()
                statusBadge
            }

            switch state.installState {
            case .checking:
                installControls
            case .notInstalled:
                installControls
            case .installed:
                actionControls
            }
        }
        .padding()
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
        .devHubSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityCardLabel)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch state.installState {
        case .checking:
            ProgressView().controlSize(.small)
        case .installed(let version):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DevHubTheme.green)
                if let version, !version.isEmpty {
                    Text(version)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .accessibilityLabel(installedAccessibility(version: version))
        case .notInstalled:
            Label(String(localized: "未安装"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.18), in: Capsule())
                .foregroundStyle(.orange)
                .accessibilityLabel(String(localized: "未安装"))
        }
    }

    /// 未安装/检测中：安装按钮或打开下载页。
    @ViewBuilder
    private var installControls: some View {
        if case .checking = state.installState {
            Text(String(localized: "正在检测…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button(action: onInstall) {
                Label(installActionTitle, systemImage: installActionIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .accessibilityHint(installActionHint)
        }
    }

    /// 已安装：原有启动控件。
    @ViewBuilder
    private var actionControls: some View {
        if state.actionStyle == .cliDualAction {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    terminalButton
                    if state.canInjectMemory { memoryButton }
                }
                VStack(spacing: 8) {
                    terminalButton
                    if state.canInjectMemory { memoryButton }
                }
            }
        } else {
            Button(action: onOpenGui) {
                Label(String(localized: "打开项目"), systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint(String(localized: "用此工具打开项目目录"))
        }
    }

    private var terminalButton: some View {
        Button(action: onContinueInTerminal) {
            Label(String(localized: "直接启动"), systemImage: "terminal")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityHint(String(localized: "在 Terminal 打开此工具，不注入项目记忆"))
    }

    private var memoryButton: some View {
        Button(action: onContinueWithMemory) {
            Label(memoryActionTitle, systemImage: state.usesClipboard ? "doc.on.clipboard" : "brain")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .accessibilityHint(injectButtonHint)
    }

    private var installActionTitle: String {
        switch state.installMethod {
        case .brew, .npm: return String(localized: "一键安装")
        case .manual:     return String(localized: "前往下载")
        }
    }

    private var installActionIcon: String {
        switch state.installMethod {
        case .brew, .npm: return "arrow.down.circle"
        case .manual:     return "arrow.up.right.square"
        }
    }

    private var installActionHint: String {
        switch state.installMethod {
        case .brew: return String(localized: "通过 Homebrew 安装此工具")
        case .npm:  return String(localized: "通过 npm 全局安装此工具")
        case .manual: return String(localized: "打开官方下载页")
        }
    }

    private func installedAccessibility(version: String?) -> String {
        var s = String(localized: "已安装")
        if let version, !version.isEmpty { s += " " + String(localized: "版本 \(version)") }
        return s
    }

    private var accessibilityCardLabel: String {
        var parts = [String(localized: "\(state.tool.name) 工具卡片")]
        switch state.installState {
        case .checking: parts.append(String(localized: "正在检测安装状态"))
        case .installed(let v): parts.append(installedAccessibility(version: v))
        case .notInstalled: parts.append(String(localized: "未安装"))
        }
        return ListFormatter.localizedString(byJoining: parts)
    }

    private var capabilityBadges: some View {
        HStack {
            ForEach(state.capabilitiesBadges, id: \.self) { badge in
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(DevHubTheme.accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DevHubTheme.accent.opacity(0.09), in: Capsule())
            }
        }
        .accessibilityHidden(true)  // 能力已并入卡片 label，避免重复朗读
    }

    private var injectButtonHint: String {
        if state.usesClipboard {
            return String(localized: "复制项目记忆并启动工具；启动后需要在工具中手动粘贴")
        }
        // codex 特别警告
        if state.adapter?.toolId == "codex" {
            return String(localized: "向 codex 发送项目记忆并立即发起一轮新对话")
        }
        return String(localized: "启动工具并附加项目记忆作为系统上下文")
    }

    private var memoryActionTitle: String {
        state.usesClipboard
            ? String(localized: "复制记忆并启动")
            : String(localized: "启动并发送项目记忆")
    }
}
