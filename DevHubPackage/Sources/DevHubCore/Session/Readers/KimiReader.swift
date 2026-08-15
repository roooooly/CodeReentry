import Foundation

/// Kimi 数据路径（§5.3）。
public struct KimiPaths: Equatable, Sendable {
    public let appBundleId: String          // "com.moonshot.kimichat"
    public let userDataDir: URL             // ~/Library/Application Support/kimi-desktop
    public let agentStateDir: URL           // .../kimi-agent
    public let conversationStatuses: URL    // .../conversation-statuses.json
    public let conversationContextUsage: URL// .../conversation-context-usage.json
    public let logFile: URL                 // ~/Library/Logs/kimi-desktop/main.log
    /// LevelDB 目录（v1.1+ 完整内容解析用；P2 仅记录路径，不读）。
    public let indexedDbDir: URL?

    public init(appBundleId: String, userDataDir: URL, agentStateDir: URL,
                conversationStatuses: URL, conversationContextUsage: URL,
                logFile: URL, indexedDbDir: URL?) {
        self.appBundleId = appBundleId
        self.userDataDir = userDataDir
        self.agentStateDir = agentStateDir
        self.conversationStatuses = conversationStatuses
        self.conversationContextUsage = conversationContextUsage
        self.logFile = logFile
        self.indexedDbDir = indexedDbDir
    }
}

public struct KimiCandidate: Sendable, Equatable {
    public let userDataDir: URL
    public let markerFile: String        // 相对 userDataDir

    public init(userDataDir: URL, markerFile: String) {
        self.userDataDir = userDataDir; self.markerFile = markerFile
    }
}

/// 探明 Kimi 安装路径（§5.3）。
/// Kimi 是 Electron app，会话内容存在 IndexedDB（LevelDB 二进制）——v1 不解析，
/// 只索引 kimi-agent/ 下的状态 JSON（会话 id/状态/模型/上下文用量，无完整消息）。
public enum KimiPathDiscovery {

    /// 标准候选（按优先级）。第一个 marker 文件存在的胜出。
    public static func standardCandidates(home: URL) -> [KimiCandidate] {
        let appSupport = home.appendingPathComponent("Library/Application Support")
        return [
            .init(userDataDir: appSupport.appendingPathComponent("kimi-desktop"),
                  markerFile: "kimi-agent/conversation-statuses.json"),
            .init(userDataDir: appSupport.appendingPathComponent("kimi-desktop"),
                  markerFile: "Local State"),
            .init(userDataDir: appSupport.appendingPathComponent("Kimi"),
                  markerFile: "pc-attribution.json"),
        ]
    }

    public static func discover(candidates: [KimiCandidate], home: URL) -> KimiPaths? {
        let fm = FileManager.default
        for c in candidates {
            let marker = c.userDataDir.appendingPathComponent(c.markerFile)
            if fm.fileExists(atPath: marker.path) {
                let agent = c.userDataDir.appendingPathComponent("kimi-agent")
                let idb = c.userDataDir.appendingPathComponent("IndexedDB")
                let idbDir: URL? = (try? fm.contentsOfDirectory(at: idb, includingPropertiesForKeys: nil))?
                    .first
                return KimiPaths(
                    appBundleId: "com.moonshot.kimichat",
                    userDataDir: c.userDataDir,
                    agentStateDir: agent,
                    conversationStatuses: agent.appendingPathComponent("conversation-statuses.json"),
                    conversationContextUsage: agent.appendingPathComponent("conversation-context-usage.json"),
                    logFile: home.appendingPathComponent("Library/Logs/kimi-desktop/main.log"),
                    indexedDbDir: idbDir)
            }
        }
        return nil
    }
}

/// Kimi 会话 reader（§5.3）。**v1 只索引元数据**——从 conversation-statuses.json +
/// conversation-context-usage.json 提取会话 id/状态/模型/上下文用量/更新时间。
/// preview 用模型名占位（明示非真实消息内容，完整内容待 v1.1+ LevelDB 解析）。
public struct KimiReader: SessionReader {
    public let toolId = "kimi"
    public let paths: KimiPaths?

    public init(paths: KimiPaths?) { self.paths = paths }

    public func discover() async throws -> [DiscoveredSession] {
        guard let paths = paths,
              FileManager.default.fileExists(atPath: paths.conversationStatuses.path) else { return [] }
        // conversation-statuses.json 通常是 { "<sessId>": { "status": ..., "updatedAt": ... }, ... }
        guard let data = try? Data(contentsOf: paths.conversationStatuses),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }

        let contextUsage = loadContextUsage(paths.conversationContextUsage)
        let iso = ISO8601DateFormatter()
        let now = Date()
        var result: [DiscoveredSession] = []
        for (sessId, value) in obj {
            let dict = value as? [String: Any] ?? [:]
            let model = (dict["model"] as? String) ?? "kimi"
            let updatedAt = (dict["updatedAt"] as? String).flatMap { iso.date(from: $0) } ?? now
            let usageInfo = contextUsage[sessId].map { " · \($0) tokens" } ?? ""
            result.append(DiscoveredSession(
                tool: toolId,
                toolSessionId: sessId,
                sourcePath: paths.conversationStatuses.path,
                projectCwd: "",  // Kimi 元数据无 cwd
                startedAt: updatedAt,
                updatedAt: updatedAt,
                messageCount: 0,
                title: nil,
                preview: "[\(model)\(usageInfo)] " + String(localized: "元数据索引（完整内容待 v1.1+）")
            ))
        }
        return result
    }

    public func load(_ id: String) async throws -> SessionDetail {
        // v1 无完整消息内容（LevelDB 二进制）——返回空 messages + 元数据占位
        SessionDetail(tool: toolId, toolSessionId: id, cwd: "", startedAt: Date(), messages: [])
    }

    private func loadContextUsage(_ url: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in obj {
            if let dict = v as? [String: Any], let used = dict["used"] {
                out[k] = String(describing: used)
            }
        }
        return out
    }
}
