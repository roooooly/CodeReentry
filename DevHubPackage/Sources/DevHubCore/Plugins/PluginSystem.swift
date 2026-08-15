import Foundation

/// 插件所在的轨道（§6）。
public enum PluginRail: String, Codable, Sendable, Equatable {
    case builtin   // Rail A：内置 Swift
    case mcp       // Rail B：MCP stdio
    case script    // Rail C：脚本
}

/// 插件权限声明（§6.4）。v1 仅声明式文档 + 首次启用确认，运行时强制留 v2。
public enum Permission: String, Codable, Sendable, Equatable, CaseIterable {
    case filesystem
    case network
    case process
    case automation
}

/// 插件清单（§6）。
public struct PluginManifest: Codable, Sendable, Equatable {
    public var name: String
    public var version: String
    public var rail: PluginRail
    public var permissions: [Permission]
    public var minAppVersion: String?

    public init(name: String, version: String, rail: PluginRail,
                permissions: [Permission] = [], minAppVersion: String? = nil) {
        self.name = name
        self.version = version
        self.rail = rail
        self.permissions = permissions
        self.minAppVersion = minAppVersion
    }
}

// MARK: - 贡献点（§6.1）

/// 添加一个工具到启动器（MCP server 的工具走此贡献点）。
public struct ToolContribution: Sendable, Equatable, Identifiable {
    public let id: String          // 插件内唯一，如 "mcp.filesystem.read_file"
    public let title: String
    public let subtitle: String?
    public let sourcePluginId: String

    public init(id: String, title: String, subtitle: String? = nil, sourcePluginId: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.sourcePluginId = sourcePluginId
    }
}

/// 添加一个 AI 会话 reader（如 zcode reader 走此贡献点）。
public struct SessionReaderContribution: Sendable, Equatable {
    public let reader: any SessionReader
    public let sourcePluginId: String

    public init(reader: any SessionReader, sourcePluginId: String) {
        self.reader = reader
        self.sourcePluginId = sourcePluginId
    }

    public static func == (lhs: SessionReaderContribution, rhs: SessionReaderContribution) -> Bool {
        lhs.sourcePluginId == rhs.sourcePluginId
            && lhs.reader.toolId == rhs.reader.toolId
    }
}

/// 添加一个动作（右键/工具栏，Rail C action 走此贡献点）。
public struct ActionContribution: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let scope: ActionScope
    public let sourcePluginId: String

    public enum ActionScope: String, Sendable, Equatable {
        case project
        case session
        case global
    }

    public init(id: String, title: String, scope: ActionScope, sourcePluginId: String) {
        self.id = id
        self.title = title
        self.scope = scope
        self.sourcePluginId = sourcePluginId
    }
}

/// 贡献注册表——插件 contribute(to:) 时往里登记；app 聚合查询所有插件的贡献（§6.1）。
/// 值类型，按插件遍历后由调用方合并。
public struct ContributionRegistry: Sendable {
    public var tools: [ToolContribution] = []
    public var sessionReaders: [SessionReaderContribution] = []
    public var actions: [ActionContribution] = []

    public init() {}

    public mutating func register(tool: ToolContribution) { tools.append(tool) }
    public mutating func register(reader: SessionReaderContribution) { sessionReaders.append(reader) }
    public mutating func register(action: ActionContribution) { actions.append(action) }

    /// 合并多个插件的贡献（按注册顺序，不去重——重复由消费方决定）。
    public static func merge(_ registries: [ContributionRegistry]) -> ContributionRegistry {
        var merged = ContributionRegistry()
        for r in registries {
            merged.tools.append(contentsOf: r.tools)
            merged.sessionReaders.append(contentsOf: r.sessionReaders)
            merged.actions.append(contentsOf: r.actions)
        }
        return merged
    }
}

/// 插件协议（§6）。
/// Rail A 内置模块、Rail B MCP、Rail C 脚本都实现此协议。
public protocol DevHubPlugin: Sendable {
    var id: String { get }
    var manifest: PluginManifest { get }
    /// 向注册表贡献能力。异步以支持 MCP 等 IO 型插件。
    func contribute(to registry: inout ContributionRegistry) async
}
