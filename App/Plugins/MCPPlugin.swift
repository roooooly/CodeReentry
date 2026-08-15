import Foundation
import OSLog
import DevHubCore

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "mcp-supervisor")

struct MCPServerSnapshot: Identifiable, Sendable, Equatable {
    let name: String
    let status: MCPClientStatus
    var id: String { name }
}

@MainActor
protocol MCPToolCalling: AnyObject {
    func callTool(
        serverName: String,
        toolName: String,
        argumentsJSON: String
    ) async throws -> MCPToolCallResult
}

/// 一个 MCP server 作为 DevHubPlugin 暴露（§6.3）。
/// contribute(to:) 时把 server 暴露的工具登记为 ToolContribution。
@MainActor
final class MCPPlugin: DevHubPlugin {
    let id: String
    let manifest: PluginManifest
    let client: MCPClient

    init(client: MCPClient) {
        self.client = client
        self.id = "mcp.\(client.name)"
        self.manifest = PluginManifest(
            name: client.name,
            version: "1.0",
            rail: .mcp,
            permissions: [.process]
        )
    }

    func contribute(to registry: inout ContributionRegistry) async {
        let tools = await client.listTools()
        for tool in tools {
            registry.register(tool: tool)
        }
    }
}

/// 多 MCP server 聚合状态（§6.3）。
/// 启动时读 MCPConfigStore.load()，为每个 server 创建 MCPClient + MCPPlugin。
@MainActor
final class MCPClientSupervisor: MCPToolCalling {
    /// Posted after every initial load or reload attempt, including a failed
    /// configuration read. Consumers must re-query instead of retaining stale tools.
    static let toolsChangedNotification = Notification.Name("DevHubMCPToolsChanged")

    private(set) var clients: [MCPClient] = []
    private(set) var plugins: [MCPPlugin] = []
    let configStore: MCPConfigStore
    private let notificationCenter: NotificationCenter
    private let handshakeTimeout: TimeInterval
    private let reconnectPolicy: MCPReconnectPolicy

    init(
        configStore: MCPConfigStore = MCPConfigStore(),
        notificationCenter: NotificationCenter = .default,
        handshakeTimeout: TimeInterval = 10,
        reconnectPolicy: MCPReconnectPolicy = MCPReconnectPolicy()
    ) {
        self.configStore = configStore
        self.notificationCenter = notificationCenter
        self.handshakeTimeout = handshakeTimeout
        self.reconnectPolicy = reconnectPolicy
    }

    /// 加载配置 + 启动所有 server（异步，各自跑重连策略）。
    func startAll() async {
        defer {
            notificationCenter.post(name: Self.toolsChangedNotification, object: self)
        }
        let config: MCPConfig
        do {
            config = try configStore.load()
        } catch {
            logger.error("加载 mcp.json 失败: \(error.localizedDescription, privacy: .public)")
            return
        }
        clients.removeAll()
        plugins.removeAll()
        for (name, serverCfg) in config.servers.sorted(by: { $0.key < $1.key }) {
            let client = MCPClient(
                name: name,
                serverConfig: serverCfg,
                reconnectPolicy: reconnectPolicy,
                handshakeTimeout: handshakeTimeout
            )
            clients.append(client)
            plugins.append(MCPPlugin(client: client))
        }
        // 每个 server 独立握手；一个无响应进程不能阻止其他健康 server 可用。
        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { await client.start() }
            }
        }
    }

    /// 聚合所有 plugin 的贡献（供命令面板 / 启动器使用）。
    func allContributions() async -> ContributionRegistry {
        var merged = ContributionRegistry()
        for plugin in plugins {
            var reg = ContributionRegistry()
            await plugin.contribute(to: &reg)
            merged.tools.append(contentsOf: reg.tools)
        }
        return merged
    }

    /// 聚合状态：任一 connected 即整体可用；全 degraded 则 degraded。
    var aggregateStatus: MCPClientStatus {
        if clients.isEmpty { return .disconnected }
        if clients.contains(where: { $0.status.isUsable }) { return .connected }
        if clients.contains(where: {
            if case .connecting = $0.status { return true }
            return false
        }) {
            return .connecting
        }
        if clients.allSatisfy({
            switch $0.status {
            case .degraded, .disconnected: return true
            case .connecting, .connected: return false
            }
        }) {
            return .degraded(reason: String(localized: "所有 server 不可用"))
        }
        return .connecting
    }

    func stopAll() async {
        await withTaskGroup(of: Void.self) { group in
            for client in clients {
                group.addTask { await client.disconnect() }
            }
        }
    }

    func reload() async {
        await stopAll()
        clients.removeAll()
        plugins.removeAll()
        // Remove stale launcher commands while replacement servers connect.
        notificationCenter.post(name: Self.toolsChangedNotification, object: self)
        await startAll()
    }

    func snapshots() -> [MCPServerSnapshot] {
        clients.map { MCPServerSnapshot(name: $0.name, status: $0.status) }
    }

    func allToolInfos() async -> [MCPToolInfo] {
        var tools: [MCPToolInfo] = []
        for client in clients where client.status.isUsable {
            tools.append(contentsOf: await client.toolInfos())
        }
        return tools.sorted { $0.id < $1.id }
    }

    func callTool(
        serverName: String,
        toolName: String,
        argumentsJSON: String
    ) async throws -> MCPToolCallResult {
        guard let client = clients.first(where: { $0.name == serverName }) else {
            throw MCPClientError.notConnected(serverName)
        }
        return try await client.callTool(name: toolName, argumentsJSON: argumentsJSON)
    }
}
