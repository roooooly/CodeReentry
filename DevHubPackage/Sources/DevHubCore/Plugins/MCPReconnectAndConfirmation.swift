import Foundation

/// MCP server 崩溃重连策略（§9）。3 次指数退避，失败后降级。
public struct MCPReconnectPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let multiplier: Double
    public let maxDelay: TimeInterval

    public init(
        maxAttempts: Int = 3,
        baseDelay: TimeInterval = 1.0,
        multiplier: Double = 2.0,
        maxDelay: TimeInterval = 30.0
    ) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maxDelay = maxDelay
    }

    /// 返回下一次重连前的等待秒数；nil 表示已达上限（应转为 degraded 状态，不抛错——spec §9）。
    public func nextDelay(afterAttempt attempt: Int) -> TimeInterval? {
        guard attempt < maxAttempts else { return nil }
        let raw = baseDelay * pow(multiplier, Double(attempt))
        return min(raw, maxDelay)
    }
}

/// MCP 首次启用确认（§6.3）。
/// `npx -y` 等于远程任意执行——必须向用户展示完整 command + args，显式确认后才写入 mcp.json。
public struct MCPConfirmationGate: Sendable, Equatable, Identifiable {
    public let serverName: String
    public let server: MCPServerConfig

    public init(serverName: String, server: MCPServerConfig) {
        self.serverName = serverName
        self.server = server
    }

    public var id: String { serverName }

    /// 显示给用户的完整命令提示文本。
    public var confirmationPrompt: String {
        var lines: [String] = []
        lines.append(String(localized: "即将启动 MCP server: \(serverName)"))
        lines.append("Command: \(server.command)")
        lines.append("Args: \(server.args.joined(separator: " "))")
        if let env = server.env, !env.isEmpty {
            lines.append("Env: \(env.keys.sorted().joined(separator: ", "))")
        }
        lines.append("")
        lines.append(String(localized: "npx -y 等于远程任意执行，请确认信任来源。"))
        return lines.joined(separator: "\n")
    }

    /// 疑似敏感 env 变量的风险提示（KEY/TOKEN/SECRET）。
    public var warningLines: [String] {
        guard let env = server.env else { return [] }
        return env.keys.compactMap { k -> String? in
            let upper = k.uppercased()
            guard upper.contains("KEY") || upper.contains("TOKEN") || upper.contains("SECRET") else { return nil }
            return String(localized: "环境变量 \(k) 疑似密钥，启动后会被注入子进程")
        }
    }

    public func decide(accepted: Bool) -> MCPConfirmationDecision {
        accepted ? .accepted : .declined
    }
}

public enum MCPConfirmationDecision: String, Sendable, Equatable {
    case accepted
    case declined
}
