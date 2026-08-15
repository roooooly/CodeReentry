import Foundation
import SwiftData

/// (项目 × 平台账号) 绑定（§4.1 §5.5）。每对组合有独立的发布状态。
@Model
public final class ProjectPlatformBinding {
    @Attribute(.unique) public var id: UUID
    public var project: Project?
    public var account: PlatformAccount?
    public var publishStatusRaw: String
    public var publishUrl: String?
    public var publishNotes: String?
    public var lastPublishedAt: Date?

    public var publishStatus: PublishStatus {
        get { PublishStatus(rawValue: publishStatusRaw) ?? .draft }
        set { publishStatusRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        project: Project? = nil,
        account: PlatformAccount? = nil,
        publishStatus: PublishStatus = .draft,
        publishUrl: String? = nil,
        publishNotes: String? = nil,
        lastPublishedAt: Date? = nil
    ) {
        self.id = id
        self.project = project
        self.account = account
        self.publishStatusRaw = publishStatus.rawValue
        self.publishUrl = publishUrl
        self.publishNotes = publishNotes
        self.lastPublishedAt = lastPublishedAt
    }
}
