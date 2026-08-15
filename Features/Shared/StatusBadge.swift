import SwiftUI
import DevHubCore

/// 项目生命周期状态徽章（§项目总览卡片）。
/// 视觉语言复用 ToolCard 的 Capsule + tint.opacity(0.2)；按状态分色。
struct StatusBadge: View {
    let status: ProjectStatus

    var body: some View {
        Label(status.title, systemImage: status.systemImage)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.18), in: Capsule())
            .foregroundStyle(statusColor)
            .accessibilityLabel(String(localized: "状态：\(status.title)"))
    }

    /// 每个状态一个语义色，直观区分。
    private var statusColor: Color {
        switch status {
        case .active:      return DevHubTheme.blue
        case .completed:   return DevHubTheme.green
        case .paused:      return .gray
        case .maintaining: return DevHubTheme.gold
        case .archived:    return .secondary
        }
    }
}
