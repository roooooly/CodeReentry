import Foundation

/// Codex 用量读取器（§订阅用量与成本）。
///
/// 扫描 `~/.codex/sessions/**/*.jsonl` + `~/.codex/archived_sessions/**/*.jsonl`，
/// 对每行 `type:"event_msg"` 且 `payload.type:"token_count"` 取
/// `payload.info.last_token_usage.{input_tokens, cached_input_tokens, output_tokens, reasoning_output_tokens}`
/// （**用 last 而非 total，避免累计重复**）。
///
/// 模型名不在事件里，从 `~/.codex/config.toml` 的 `model` 字段读取（用户当期模型）。
/// 额外抽取最近一条 `rate_limits`（5h/7d 滚动窗口）。
///
/// 纯本地解析，不读 `~/.codex/auth.json`，无网络。
public struct CodexUsageReader: Sendable {
    public let rootURL: URL
    /// 当期模型（从 config.toml 解析；可被测试覆盖）。
    public let model: String

    private static let initialTailBytes: UInt64 = 512 * 1_024
    private static let expandedTailBytes: UInt64 = 4 * 1_024 * 1_024
    private static let maximumTailBytes: UInt64 = 32 * 1_024 * 1_024
    private static let cwdHeadBytes: UInt64 = 128 * 1_024

    private struct FileScan {
        let record: UsageRecord?
        let rateLimit: (date: Date, snapshot: CodexRateLimitSnapshot)?
    }

    public init(rootURL: URL? = nil, model: String? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = rootURL ?? home.appendingPathComponent(".codex")
        self.rootURL = root
        self.model = model ?? Self.readModelFromConfig(at: root.appendingPathComponent("config.toml"))
    }

    public func readAll() async -> [UsageRecord] {
        var records: [UsageRecord] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()
        for root in codexRoots() {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for await file in JsonlFileEnumerator.enumerate(in: root) {
                if let record = scan(file: file, iso: iso, noFrac: noFrac).record {
                    records.append(record)
                }
            }
        }
        return records
    }

    /// 从所有会话里取最近一条 rate_limits（按 timestamp 最新的 token_count 事件）。
    public func readLatestRateLimit() async -> CodexRateLimitSnapshot? {
        var best: (date: Date, snapshot: CodexRateLimitSnapshot)?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()
        for root in codexRoots() {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for await file in JsonlFileEnumerator.enumerate(in: root) {
                guard let snap = scan(file: file, iso: iso, noFrac: noFrac).rateLimit else { continue }
                if best == nil || snap.date > best!.date {
                    best = snap
                }
            }
        }
        return best?.snapshot
    }

    /// 一次遍历同时抽取 usage records 与最新 rate_limit，避免 readAll + readLatestRateLimit 各扫一遍。
    ///
    /// 关键正确性：Codex 的 `last_token_usage` 是**会话内累计值**（随 turn 递增），
    /// 不是增量。因此每个会话文件只取**最后一条** token_count 事件的 last 作为该会话用量，
    /// 而非累加所有事件（累加会把同一 token 反复计入，导致用量虚高几个数量级）。
    /// 实测：累加法得 2350 亿 token / $16万；取最后一条法得 4300 万 token / ~$40。
    public func readAllAndRateLimit() async -> (records: [UsageRecord], rateLimit: CodexRateLimitSnapshot?) {
        var records: [UsageRecord] = []
        var bestRate: (date: Date, snapshot: CodexRateLimitSnapshot)?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()

        for root in codexRoots() {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for await file in JsonlFileEnumerator.enumerate(in: root) {
                let result = scan(file: file, iso: iso, noFrac: noFrac)
                if let record = result.record { records.append(record) }
                if let fr = result.rateLimit, bestRate == nil || fr.date > bestRate!.date {
                    bestRate = fr
                }
            }
        }
        return (records, bestRate?.snapshot)
    }

    /// sessions 与 archived_sessions 两个根目录（顺序固定）。
    private func codexRoots() -> [URL] {
        [
            rootURL.appendingPathComponent("sessions", isDirectory: true),
            rootURL.appendingPathComponent("archived_sessions", isDirectory: true)
        ]
    }

    /// 解析单文件，返回该会话的累计用量（取最后一条 token_count 事件的 last）。
    ///
    /// `last_token_usage` 是会话内累计值（随 turn 递增），不是增量；
    /// 累加所有事件会重复计数。正确值 = 文件内最后一条 token_count 的 last。
    /// 返回单元素数组（或空，若无事件），便于上层统一 `append(contentsOf:)`。
    func parse(file: URL) -> [UsageRecord] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()
        return scan(file: file, iso: iso, noFrac: noFrac).record.map { [$0] } ?? []
    }

    /// 解析单文件里最新一条 token_count 事件的 rate_limits。
    func parseLatestRateLimit(file: URL, iso: ISO8601DateFormatter) -> (date: Date, snapshot: CodexRateLimitSnapshot)? {
        let noFrac = ISO8601DateFormatter()
        return scan(file: file, iso: iso, noFrac: noFrac).rateLimit
    }

    /// Reads only the tail of large append-only rollouts. The final token_count
    /// contains the session's cumulative usage, so a full 500 MB–1 GB pass is
    /// unnecessary. If the first window has no usable event, two bounded wider
    /// windows are tried; the reader never falls back to unbounded full-file I/O.
    private func scan(
        file: URL,
        iso: ISO8601DateFormatter,
        noFrac: ISO8601DateFormatter
    ) -> FileScan {
        let size = UInt64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        guard size > 0 else { return FileScan(record: nil, rateLimit: nil) }

        var result = scanWindow(
            file: file,
            maximumBytes: Self.initialTailBytes,
            iso: iso,
            noFrac: noFrac
        )
        if result.record == nil, size > Self.initialTailBytes {
            result = scanWindow(
                file: file,
                maximumBytes: Self.expandedTailBytes,
                iso: iso,
                noFrac: noFrac
            )
        }
        if result.record == nil, size > Self.expandedTailBytes {
            result = scanWindow(
                file: file,
                maximumBytes: Self.maximumTailBytes,
                iso: iso,
                noFrac: noFrac
            )
        }

        guard let record = result.record, record.cwd.isEmpty else { return result }
        let cwd = readCwdFromHead(file: file)
        return FileScan(
            record: UsageRecord(
                tool: record.tool,
                model: record.model,
                cwd: cwd,
                timestamp: record.timestamp,
                inputTokens: record.inputTokens,
                cacheWriteTokens: record.cacheWriteTokens,
                cacheReadTokens: record.cacheReadTokens,
                outputTokens: record.outputTokens,
                reasoningTokens: record.reasoningTokens
            ),
            rateLimit: result.rateLimit
        )
    }

    private func scanWindow(
        file: URL,
        maximumBytes: UInt64,
        iso: ISO8601DateFormatter,
        noFrac: ISO8601DateFormatter
    ) -> FileScan {
        var latestRecord: UsageRecord?
        var latestRate: (date: Date, snapshot: CodexRateLimitSnapshot)?
        let tokenNeedle = Data("\"token_count\"".utf8)
        let start = JSONLStreamReader.tailOffset(for: file, maximumBytes: maximumBytes)

        _ = try? JSONLStreamReader.forEachLine(at: file, startingAtOffset: start) { lineData in
            guard lineData.range(of: tokenNeedle) != nil,
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  (obj["type"] as? String) == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count" else { return true }

            let timestamp = parseDate(
                (obj["timestamp"] as? String) ?? "",
                iso: iso,
                noFrac: noFrac
            )
            if let info = payload["info"] as? [String: Any],
               let last = info["last_token_usage"] as? [String: Any] {
                latestRecord = UsageRecord(
                    tool: "codex",
                    model: model,
                    cwd: extractCwd(from: obj),
                    timestamp: timestamp,
                    inputTokens: int(last["input_tokens"]),
                    cacheWriteTokens: 0,
                    cacheReadTokens: int(last["cached_input_tokens"]),
                    outputTokens: int(last["output_tokens"]),
                    reasoningTokens: int(last["reasoning_output_tokens"])
                )
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                let primary = limits["primary"] as? [String: Any]
                let secondary = limits["secondary"] as? [String: Any]
                let snapshot = CodexRateLimitSnapshot(
                    primaryUsedPercent: double(primary?["used_percent"]),
                    primaryWindowMinutes: int(primary?["window_minutes"]),
                    primaryResetsAt: dateFromUnix(int(primary?["resets_at"])),
                    secondaryUsedPercent: double(secondary?["used_percent"]),
                    secondaryWindowMinutes: int(secondary?["window_minutes"]),
                    secondaryResetsAt: dateFromUnix(int(secondary?["resets_at"]))
                )
                if latestRate == nil || timestamp > latestRate!.date {
                    latestRate = (timestamp, snapshot)
                }
            }
            return true
        }
        return FileScan(record: latestRecord, rateLimit: latestRate)
    }

    private func readCwdFromHead(file: URL) -> String {
        var cwd = ""
        let cwdNeedle = Data("\"cwd\"".utf8)
        _ = try? JSONLStreamReader.forEachLine(
            at: file,
            byteLimit: Self.cwdHeadBytes
        ) { lineData in
            guard lineData.range(of: cwdNeedle) != nil,
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { return true }
            cwd = extractCwd(from: object)
            return cwd.isEmpty
        }
        return cwd
    }

    /// 从 turn_context / session_meta / payload 里推断 cwd。
    private func extractCwd(from obj: [String: Any]) -> String {
        if let payload = obj["payload"] as? [String: Any] {
            if let s = payload["cwd"] as? String, !s.isEmpty { return s }
            if let tc = payload["turn_context"] as? [String: Any], let c = tc["cwd"] as? String { return c }
        }
        return ""
    }

    private func int(_ value: Any?) -> Int {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double { return Int(d) }
        return 0
    }

    private func double(_ value: Any?) -> Double {
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber { return n.doubleValue }
        return 0
    }

    private func dateFromUnix(_ ts: Int) -> Date? {
        guard ts > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }

    private func parseDate(_ s: String, iso: ISO8601DateFormatter, noFrac: ISO8601DateFormatter) -> Date {
        if let d = iso.date(from: s) { return d }
        if let d = noFrac.date(from: s) { return d }
        return Date(timeIntervalSince1970: 0)
    }

    /// 解析 ~/.codex/config.toml 的 model 字段（简单行匹配，不引入 TOML 依赖）。
    /// 精确匹配键名 `model`（等号前的 token 必须恰好是 "model"），避免误匹配
    /// `model_provider` / `model_reasoning_effort` 等同前缀键。
    public static func readModelFromConfig(at url: URL) -> String {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return "gpt-5.1" }
        for line in LineSplitter.nonEmptyLines(content) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            guard key == "model" else { continue }
            let value = trimmed[trimmed.index(after: eq)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            if !value.isEmpty { return value }
        }
        return "gpt-5.1"
    }
}
