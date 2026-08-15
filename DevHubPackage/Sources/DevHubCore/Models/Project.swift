import Foundation
import SwiftData

/// 项目注册表（§4.1）。
/// stableId 是跨机身份锚点，存于 `.devhub/project.local.json`（Task 17 写入）。
@Model
public final class Project {
    @Attribute(.unique) public var id: UUID
    public var stableId: String
    public var name: String
    public var path: String
    public var icon: String?
    public var color: String?
    public var createdAt: Date
    public var lastOpenedAt: Date?
    public var isPinned: Bool
    public var group: String?
    public var tags: [String]
    /// 生命周期状态（rawValue of `ProjectStatus`）。可选以兼容旧库轻量迁移；
    /// 读取时通过 `statusEnum` 兜底为 `.active`。
    public var status: String?
    /// 当前版本号（自由文本，如 "1.2.0"）。可选以兼容旧库。
    public var version: String?

    @Relationship(deleteRule: .nullify, inverse: \Tool.projects)
    public var tools: [Tool] = []

    @Relationship(deleteRule: .nullify, inverse: \Subscription.project)
    public var subscriptions: [Subscription] = []

    @Relationship(deleteRule: .cascade, inverse: \ProjectPlatformBinding.project)
    public var platformBindings: [ProjectPlatformBinding] = []

    @Relationship(deleteRule: .cascade, inverse: \SessionIndex.project)
    public var sessions: [SessionIndex] = []

    public init(
        id: UUID = UUID(),
        stableId: String,
        name: String,
        path: String,
        icon: String? = nil,
        color: String? = nil,
        createdAt: Date = Date(),
        lastOpenedAt: Date? = nil,
        isPinned: Bool = false,
        group: String? = nil,
        tags: [String] = [],
        status: ProjectStatus = .active,
        version: String = ""
    ) {
        self.id = id
        self.stableId = stableId
        self.name = name
        self.path = path
        self.icon = icon
        self.color = color
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.isPinned = isPinned
        self.group = group
        self.tags = tags
        self.status = status.rawValue
        self.version = version.isEmpty ? nil : version
    }

    /// 生命周期状态（解码 rawValue，未知值/nil 兜底为 `.active`）。
    public var statusEnum: ProjectStatus {
        get {
            guard let raw = status, let s = ProjectStatus(rawValue: raw) else { return .active }
            return s
        }
        set { status = newValue.rawValue }
    }

    /// 版本号，nil/空统一返回 ""。
    public var versionString: String {
        get { version ?? "" }
        set { version = newValue.isEmpty ? nil : newValue }
    }
}
