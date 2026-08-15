import Foundation
@preconcurrency import SwiftData

public enum DevHubSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [Project.self, Tool.self, Subscription.self,
         PlatformAccount.self, ProjectPlatformBinding.self,
         SessionIndex.self, AppSettings.self]
    }
}
