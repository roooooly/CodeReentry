import Foundation
import SwiftData

/// 平台账号本体（§4.1 §5.5）。一个账号可被多项目复用。
/// v1 不存 cookie/凭证（§4.1：keychainKey 字段移除，留 v2 评估）。
@Model
public final class PlatformAccount {
    @Attribute(.unique) public var id: UUID
    public var platformRaw: String
    public var displayName: String
    public var loginUrl: String

    public var platform: Platform {
        get { Platform(rawValue: platformRaw) ?? .twitter }
        set { platformRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        platform: Platform,
        displayName: String,
        loginUrl: String
    ) {
        self.id = id
        self.platformRaw = platform.rawValue
        self.displayName = displayName
        self.loginUrl = loginUrl
    }
}
