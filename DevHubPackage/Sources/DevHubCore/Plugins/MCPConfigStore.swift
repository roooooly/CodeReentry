import Foundation

/// MCP server 配置（§6.3，与 Claude Desktop 同 schema）。
public struct MCPServerConfig: Codable, Sendable, Equatable {
    public let command: String
    public let args: [String]
    public let env: [String: String]?

    public init(command: String, args: [String], env: [String: String]? = nil) {
        self.command = command
        self.args = args
        self.env = env
    }
}

/// MCP 全量配置：`{ "mcpServers": { ... } }`。
/// 单一来源 `~/Library/Application Support/DevHub/mcp.json`，不入 SwiftData（§4.3 / §6.3）。
public struct MCPConfig: Codable, Sendable, Equatable {
    public var servers: [String: MCPServerConfig]

    enum CodingKeys: String, CodingKey { case servers = "mcpServers" }

    public init(servers: [String: MCPServerConfig] = [:]) { self.servers = servers }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 只有“磁盘上没有 mcp.json”才代表空配置。只要文件存在，
        // wrapper 缺失、null 或类型错误都必须抛错，否则 UI 会把损坏文件
        // 当成空配置并在下次编辑时覆盖用户数据。
        guard c.contains(.servers) else {
            throw MCPConfigError.missingServersKey
        }
        servers = try c.decode([String: MCPServerConfig].self, forKey: .servers)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(servers, forKey: .servers)
    }
}

public enum MCPConfigError: Error, LocalizedError, Sendable, Equatable {
    case missingServersKey

    public var errorDescription: String? {
        switch self {
        case .missingServersKey:
            return String(localized: "mcp.json 缺少必需的 mcpServers 字段。")
        }
    }
}

/// 读写 mcp.json。默认目录 `~/Library/Application Support/DevHub/`。
public struct MCPConfigStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let fm = FileManager.default
            let support = (try? fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )) ?? fm.homeDirectoryForCurrentUser
            self.directory = support.appendingPathComponent("DevHub", isDirectory: true)
        }
    }

    public var configPath: URL { directory.appendingPathComponent("mcp.json") }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func load() throws -> MCPConfig {
        guard FileManager.default.fileExists(atPath: configPath.path) else {
            return MCPConfig(servers: [:])
        }
        let data = try Data(contentsOf: configPath)
        return try JSONDecoder().decode(MCPConfig.self, from: data)
    }

    public func save(_ config: MCPConfig) throws {
        // save 是 public API，不能只依赖 add/remove 事先 load 的约定。
        // 已有文件若无法解码，必须由用户先修复；绝不用新的内存配置覆盖。
        if FileManager.default.fileExists(atPath: configPath.path) {
            _ = try load()
        }
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: configPath, options: .atomic)
    }

    public func addServer(name: String, command: String, args: [String], env: [String: String]?) throws {
        var cfg = try load()
        cfg.servers[name] = MCPServerConfig(command: command, args: args, env: env)
        try save(cfg)
    }

    public func removeServer(name: String) throws {
        var cfg = try load()
        cfg.servers[name] = nil
        try save(cfg)
    }
}

/// MCP client 状态（§6.3 降级状态）。
public enum MCPClientStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case degraded(reason: String)

    public var isUsable: Bool {
        if case .connected = self { return true }
        return false
    }

    public var localizedDescription: String {
        switch self {
        case .disconnected: return String(localized: "未连接")
        case .connecting:   return String(localized: "连接中…")
        case .connected:    return String(localized: "已连接")
        case .degraded(let reason): return String(localized: "降级：\(reason)")
        }
    }
}
