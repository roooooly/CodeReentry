import Foundation

/// 平台的一键打开方式（§5.5）。
public enum PlatformOpenKind: Equatable, Sendable {
    case openUrl                 // NSWorkspace.open(URL)
    case openApp(String)         // open -a "WeChat DevTools"
}

public struct PlatformPreset: Equatable, Sendable {
    public let platform: Platform
    public let defaultDisplayName: String
    public let defaultLoginUrl: String
    public let openKind: PlatformOpenKind

    public init(platform: Platform, defaultDisplayName: String,
                defaultLoginUrl: String, openKind: PlatformOpenKind) {
        self.platform = platform
        self.defaultDisplayName = defaultDisplayName
        self.defaultLoginUrl = defaultLoginUrl
        self.openKind = openKind
    }
}

/// 5 个预置平台（§5.5）：微信小程序/公众号/开发者工具、X、小红书。
public enum PlatformPresets {
    public static let all: [PlatformPreset] = [
        .init(platform: .wechatMini,
              defaultDisplayName: String(localized: "微信小程序"),
              defaultLoginUrl: "https://mp.weixin.qq.com/",
              openKind: .openUrl),
        .init(platform: .wechatOA,
              defaultDisplayName: String(localized: "微信公众号"),
              defaultLoginUrl: "https://mp.weixin.qq.com/",
              openKind: .openUrl),
        .init(platform: .wechatDevTools,
              defaultDisplayName: String(localized: "微信开发者工具"),
              defaultLoginUrl: "weixin-devtools://",
              openKind: .openApp("WeChat DevTools")),
        .init(platform: .twitter,
              defaultDisplayName: "X (Twitter)",
              defaultLoginUrl: "https://x.com/",
              openKind: .openUrl),
        .init(platform: .xiaohongshu,
              defaultDisplayName: String(localized: "小红书"),
              defaultLoginUrl: "https://creator.xiaohongshu.com/",
              openKind: .openUrl),
    ]

    public static func preset(for p: Platform) -> PlatformPreset? {
        all.first { $0.platform == p }
    }
}

extension PublishStatus {
    /// v1 宽松策略：个人工具，allow-all 转移（v2 才收紧）。
    /// UI 用此方法决定按钮是否可点——目前恒 true，保留 API 以便 v2 收紧。
    public func canTransition(to: PublishStatus) -> Bool { true }
}

// MARK: - Sendable snapshots（@ModelActor store 返回值，跨 actor 传递）

public struct PlatformAccountSnapshot: Sendable, Equatable {
    public let id: UUID
    public let platform: Platform
    public let displayName: String
    public let loginUrl: String

    public init(id: UUID, platform: Platform, displayName: String, loginUrl: String) {
        self.id = id; self.platform = platform
        self.displayName = displayName; self.loginUrl = loginUrl
    }

    public init(_ acc: PlatformAccount) {
        self.id = acc.id; self.platform = acc.platform
        self.displayName = acc.displayName; self.loginUrl = acc.loginUrl
    }
}

public struct PlatformBindingSnapshot: Sendable, Equatable {
    public let id: UUID
    public let projectId: UUID?
    public let accountId: UUID?
    public let publishStatus: PublishStatus
    public let publishUrl: String?
    public let publishNotes: String?
    public let lastPublishedAt: Date?

    public init(id: UUID, projectId: UUID?, accountId: UUID?, publishStatus: PublishStatus,
                publishUrl: String?, publishNotes: String?, lastPublishedAt: Date?) {
        self.id = id; self.projectId = projectId; self.accountId = accountId
        self.publishStatus = publishStatus; self.publishUrl = publishUrl
        self.publishNotes = publishNotes; self.lastPublishedAt = lastPublishedAt
    }

    public init(_ b: ProjectPlatformBinding) {
        self.id = b.id
        self.projectId = b.project?.id
        self.accountId = b.account?.id
        self.publishStatus = b.publishStatus
        self.publishUrl = b.publishUrl
        self.publishNotes = b.publishNotes
        self.lastPublishedAt = b.lastPublishedAt
    }
}
