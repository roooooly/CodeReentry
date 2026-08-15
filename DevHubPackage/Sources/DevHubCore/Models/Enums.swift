import Foundation

public enum ToolKind: String, Codable, Sendable, CaseIterable {
    case cli      // claude / codex / zcode-cli
    case app      // GUI app: VS Code / Kimi
    case mcp      // MCP server (Rail B)
}

public enum WorkingDirMode: String, Codable, Sendable, CaseIterable {
    case projectRoot
    case custom
}

public enum InjectionMode: String, Codable, Sendable, CaseIterable {
    case cliFlag        // Claude --append-system-prompt-file <tmpfile>
    case positionalArg  // codex resume <id> "<prompt>"
    case clipboard      // fallback: clipboard + toast
}

public enum Platform: String, Codable, Sendable, CaseIterable {
    case wechatMini
    case wechatOA
    case wechatDevTools
    case twitter
    case xiaohongshu
}

public enum PublishStatus: String, Codable, Sendable, CaseIterable {
    case draft
    case inReview
    case published
    case needsUpdate
}

/// 项目生命周期状态（§项目总览卡片）。
/// 以 rawValue 持久化到 `Project.status`，默认 `active`。
public enum ProjectStatus: String, Codable, Sendable, CaseIterable {
    case active       // 进行中
    case completed    // 已完成
    case paused       // 暂停
    case maintaining  // 维护
    case archived     // 归档

    public var title: String {
        switch self {
        case .active:       return String(localized: "进行中")
        case .completed:    return String(localized: "已完成")
        case .paused:       return String(localized: "暂停")
        case .maintaining:  return String(localized: "维护")
        case .archived:     return String(localized: "归档")
        }
    }

    public var systemImage: String {
        switch self {
        case .active:       return "circle.fill"
        case .completed:    return "checkmark.circle.fill"
        case .paused:       return "pause.circle.fill"
        case .maintaining:  return "wrench.adjustable.fill"
        case .archived:     return "archivebox.fill"
        }
    }
}

/// 工具的安装方式，用于「未安装 → 一键安装」的执行策略（§工具管理）。
/// - `manual`: 手动下载安装（DevHub 只能打开下载页）
/// - `brew`:   Homebrew 包/cask（DevHub 跑 `brew install`）
/// - `npm`:    npm 全局包（DevHub 跑 `npm install -g`）
public enum InstallMethod: String, Codable, Sendable, CaseIterable {
    case manual
    case brew
    case npm
}
