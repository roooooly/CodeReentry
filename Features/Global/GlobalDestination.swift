import Foundation

enum GlobalDestination: String, CaseIterable, Hashable, Sendable {
    case projects
    case usage
    case subscriptions
    case sessions
    case evidence
    case platforms

    var selectionTag: String { "__global__:\(rawValue)" }

    init?(selectionTag: String) {
        guard selectionTag.hasPrefix("__global__:") else { return nil }
        self.init(rawValue: String(selectionTag.dropFirst("__global__:".count)))
    }

    var title: String {
        switch self {
        case .projects: return String(localized: "项目总览")
        case .usage: return String(localized: "用量与成本")
        case .subscriptions: return String(localized: "订阅总览")
        case .sessions: return String(localized: "全部会话")
        case .evidence: return String(localized: "恢复证据")
        case .platforms: return String(localized: "平台账号")
        }
    }

    var systemImage: String {
        switch self {
        case .projects: return "square.grid.2x2.fill"
        case .usage: return "chart.bar.fill"
        case .subscriptions: return "creditcard.fill"
        case .sessions: return "bubble.left.and.bubble.right"
        case .evidence: return "stopwatch.fill"
        case .platforms: return "globe"
        }
    }
}
