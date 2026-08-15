import Foundation
import SwiftData

/// 全局配置（§4.1 §7.4）。单例：固定 id。
/// MCP 配置不入库（§6.3，存磁盘 mcp.json）。
@Model
public final class AppSettings {
    @Attribute(.unique) public var id: UUID
    public var projectsRoot: String
    public var enabledPlugins: [String]
    public var theme: String
    public var sidebarWidth: Double
    public var locale: String

    public init(
        id: UUID = UUID(),
        projectsRoot: String = "~/Projects",
        enabledPlugins: [String] = [],
        theme: String = "system",
        sidebarWidth: Double = 240,
        locale: String = "zh-CN"
    ) {
        self.id = id
        self.projectsRoot = projectsRoot
        self.enabledPlugins = enabledPlugins
        self.theme = theme
        self.sidebarWidth = sidebarWidth
        self.locale = locale
    }

    public static let singletonId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    public static func singleton() -> AppSettings {
        AppSettings(id: singletonId)
    }

    @MainActor
    public static func fetchOrCreate(in ctx: ModelContext) throws -> AppSettings {
        let descriptor = FetchDescriptor<AppSettings>(
            predicate: #Predicate { $0.id == singletonId }
        )
        if let existing = try ctx.fetch(descriptor).first { return existing }
        let new = AppSettings(id: singletonId)
        ctx.insert(new)
        try ctx.save()
        return new
    }
}
