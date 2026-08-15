import SwiftUI

/// P0 实现阶段标记（用于 placeholder）
enum PlaceholderStage: String, Sendable {
    case p1 = "P1"
    case p2 = "P2"
}

enum DetailTab: String, CaseIterable, Identifiable, Hashable, Sendable {
    case tools
    case sessions
    case memory
    case subscriptions
    case platforms
    case ops

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools:         return String(localized: "工具")
        case .sessions:      return String(localized: "会话")
        case .memory:        return String(localized: "记忆")
        case .subscriptions: return String(localized: "订阅")
        case .platforms:     return String(localized: "平台")
        case .ops:           return String(localized: "运维")
        }
    }

    var systemImage: String {
        switch self {
        case .tools:         return "wrench.and.screwdriver"
        case .sessions:      return "bubble.left.and.bubble.right"
        case .memory:        return "brain.head.profile"
        case .subscriptions: return "creditcard"
        case .platforms:     return "globe"
        case .ops:           return "server.rack"
        }
    }

    /// 哪些 tab 真实可用
    var isEnabled: Bool {
        switch self {
        case .tools, .sessions, .memory, .subscriptions, .platforms, .ops: return true
        }
    }

    /// 若是 placeholder，标注阶段（当前所有 tab 均已实现，返回 nil）。
    var placeholderStage: PlaceholderStage? {
        nil
    }
}

enum DetailTabVisibilityError: Error, LocalizedError, Equatable {
    case cannotDisableLastTab

    var errorDescription: String? {
        switch self {
        case .cannotDisableLastTab:
            return String(localized: "至少需要保留一个项目详情模块。")
        }
    }
}

/// Tab 切换可观察状态。独立测试，不依赖视图。
@Observable
@MainActor
final class ProjectRouter {
    var selectedTab: DetailTab = .tools

    func select(_ tab: DetailTab) {
        guard tab.isEnabled else { return }
        selectedTab = tab
    }

    func select(_ tab: DetailTab, enabledTabs: [DetailTab]) {
        guard tab.isEnabled, enabledTabs.contains(tab) else { return }
        selectedTab = tab
    }

    /// 当前模块被用户关闭后，稳定回退到第一个启用模块。
    func reconcile(enabledTabs: [DetailTab]) {
        selectedTab = resolvedSelection(enabledTabs: enabledTabs)
    }

    func resolvedSelection(enabledTabs: [DetailTab]) -> DetailTab {
        if enabledTabs.contains(selectedTab) { return selectedTab }
        return enabledTabs.first ?? .tools
    }
}
