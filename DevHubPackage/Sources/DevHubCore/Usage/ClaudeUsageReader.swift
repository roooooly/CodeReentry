import Foundation

/// Claude Code 用量读取器（§订阅用量与成本）。
///
/// 扫描 `~/.claude/projects/**/*.jsonl`，对每行 `type:"assistant"` 取
/// `message.usage.{input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens}`
/// + `message.model` + `cwd` + `timestamp`，输出 `[UsageRecord]`。
///
/// 纯本地解析，不读 `~/.claude/credentials.json`，无网络。逐行流式读，单文件大不一次性 parse。
public struct ClaudeUsageReader: Sendable {
    public let projectsRoot: URL

    public init(projectsRoot: URL? = nil) {
        self.projectsRoot = projectsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("projects")
    }

    public func readAll() async -> [UsageRecord] {
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else { return [] }
        var records: [UsageRecord] = []
        for await file in JsonlFileEnumerator.enumerate(in: projectsRoot, skipSubagents: true) {
            records.append(contentsOf: parse(file: file))
        }
        return records
    }

    /// 逐行解析单个 jsonl，抽取 assistant 行的 usage。
    /// 使用分块读取避免大日志产生完整 Data/String/行数组三份副本。
    func parse(file: URL) -> [UsageRecord] {
        var records: [UsageRecord] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()
        let usageNeedle = Data("\"usage\"".utf8)

        _ = try? JSONLStreamReader.forEachLine(at: file) { lineData in
            // assistant usage 行才需要进入 Foundation JSON parser。
            guard lineData.range(of: usageNeedle) != nil else { return true }
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["type"] as? String) == "assistant" else { return true }
            guard let message = obj["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else { return true }
            let model = (message["model"] as? String) ?? "unknown"
            let cwd = (obj["cwd"] as? String) ?? ""
            let timestamp = parseDate((obj["timestamp"] as? String) ?? "", iso: iso, noFrac: noFrac)
            records.append(UsageRecord(
                tool: "claude-code",
                model: model,
                cwd: cwd,
                timestamp: timestamp,
                inputTokens: int(usage["input_tokens"]),
                cacheWriteTokens: int(usage["cache_creation_input_tokens"]),
                cacheReadTokens: int(usage["cache_read_input_tokens"]),
                outputTokens: int(usage["output_tokens"]),
                reasoningTokens: 0
            ))
            return true
        }
        return records
    }

    private func int(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        return 0
    }

    private func parseDate(_ s: String, iso: ISO8601DateFormatter, noFrac: ISO8601DateFormatter) -> Date {
        if let d = iso.date(from: s) { return d }
        if let d = noFrac.date(from: s) { return d }
        return Date(timeIntervalSince1970: 0)
    }
}
