import Foundation

/// codex session reader（§5.3A）。
/// 扫描 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl + ~/.codex/archived_sessions/。
/// cwd 从 payload 读（payload 可以是 cwd 字符串或含 cwd 的对象）。
public struct CodexReader: SessionReader {
    public let toolId = "codex"
    public let rootURL: URL

    private static let fullMetadataScanThreshold: Int = 1 * 1_024 * 1_024
    private static let quickMetadataScanBytes: UInt64 = 2 * 1_024 * 1_024
    private static let detailScanBytes: UInt64 = 64 * 1_024 * 1_024
    private static let detailMessageLimit = 500
    private static let detailCharacterLimit = 2_000_000
    private static let perMessageCharacterLimit = 50_000

    private struct SessionIndexEntry {
        let title: String?
        let updatedAt: Date?
    }

    public init(rootURL: URL? = nil) {
        self.rootURL = rootURL ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    public func discover() async throws -> [DiscoveredSession] {
        try await discover(knownFiles: [:])
    }

    public func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession] {
        var results: [DiscoveredSession] = []
        let sessionIndex = readSessionIndex()
        var normalizedKnownFiles: [String: Date] = [:]
        for (path, indexedAt) in knownFiles {
            let normalized = JSONLStreamReader.canonicalPath(path)
            normalizedKnownFiles[normalized] = max(
                normalizedKnownFiles[normalized] ?? .distantPast,
                indexedAt
            )
        }
        // active sessions: ~/.codex/sessions/YYYY/MM/DD/
        let sessionsRoot = rootURL.appendingPathComponent("sessions", isDirectory: true)
        if FileManager.default.fileExists(atPath: sessionsRoot.path) {
            try walkJsonl(
                in: sessionsRoot,
                knownFiles: normalizedKnownFiles,
                sessionIndex: sessionIndex,
                into: &results
            )
        }
        // archived: ~/.codex/archived_sessions/
        let archRoot = rootURL.appendingPathComponent("archived_sessions", isDirectory: true)
        if FileManager.default.fileExists(atPath: archRoot.path) {
            try walkJsonl(
                in: archRoot,
                knownFiles: normalizedKnownFiles,
                sessionIndex: sessionIndex,
                into: &results
            )
        }
        return results
    }

    public func load(_ id: String) async throws -> SessionDetail {
        guard let file = findFile(forSessionId: id) else {
            throw NSError(domain: "notFound", code: 404)
        }
        return try parseDetail(at: file, sessionId: id)
    }

    private func walkJsonl(
        in dir: URL,
        knownFiles: [String: Date],
        sessionIndex: [String: SessionIndexEntry],
        into results: inout [DiscoveredSession]
    ) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        for item in contents {
            let values = try? item.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                try walkJsonl(
                    in: item,
                    knownFiles: knownFiles,
                    sessionIndex: sessionIndex,
                    into: &results
                )
            } else if item.pathExtension == "jsonl" {
                let mtime = values?.contentModificationDate ?? .distantPast
                let canonicalPath = JSONLStreamReader.canonicalPath(item.path)
                if let indexedAt = knownFiles[canonicalPath], indexedAt >= mtime { continue }
                let sessionId = extractSessionId(from: item)
                if let discovered = try? parseJsonl(at: item, indexEntry: sessionIndex[sessionId]) {
                    results.append(discovered)
                }
            }
        }
    }

    /// 从文件名提取 sessionId：rollout-<ts>-<uuid>.jsonl → 取 <uuid> 段。
    /// 先剥掉 `rollout-YYYY-MM-DDTHH-MM-SS-` 前缀（codex 时间戳格式），剩下来的就是 sessionId。
    /// 若前缀不匹配，退回到正则找标准 UUID；再不行就用整个 name。
    func extractSessionId(from file: URL) -> String {
        let name = file.deletingPathExtension().lastPathComponent
        // rollout-2026-07-03T22-11-32-<sessionId>
        // 前缀: rollout-YYYY-MM-DDTHH-MM-SS-
        if let range = name.range(of: #"^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-"#, options: .regularExpression) {
            return String(name[range.upperBound...])
        }
        // 退回：标准 UUID 正则
        if let range = name.range(of: #"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#, options: .regularExpression) {
            return String(name[range])
        }
        return name
    }

    private func parseJsonl(at file: URL, indexEntry: SessionIndexEntry?) throws -> DiscoveredSession {
        let sessionId = extractSessionId(from: file)
        var cwd = ""
        var firstUserContent: String?
        var messageCount = 0
        var earliest: Date?
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let fileSize = values.fileSize ?? 0
        let boundedMetadataScan = fileSize > Self.fullMetadataScanThreshold

        let readResult = try JSONLStreamReader.forEachLine(
            at: file,
            byteLimit: boundedMetadataScan ? Self.quickMetadataScanBytes : nil
        ) { lineData in
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return true
            }
            // payload 可能是字符串(cwd)或对象
            if let payload = obj["payload"] {
                if let c = payload as? String, !c.isEmpty, c.hasPrefix("/") {
                    cwd = c
                } else if let payloadObj = payload as? [String: Any] {
                    if let c = payloadObj["cwd"] as? String, !c.isEmpty { cwd = c }
                    if let role = payloadObj["role"] as? String, (role == "user" || role == "assistant") {
                        let content = SessionContentExtractor.text(from: payloadObj["content"])
                        if content != nil { messageCount += 1 }
                        if role == "user", firstUserContent == nil, let c = content,
                           let display = SessionDisplayText.preview(from: c) {
                            firstUserContent = display
                        }
                    }
                }
            }
            if let ts = obj["timestamp"] as? String,
               let d = parseDate(ts, fractional: iso, plain: noFrac) {
                if earliest == nil || d < earliest! { earliest = d }
            }
            // Large files only need enough head metadata for project mapping and
            // a useful preview. Exact counts remain available when the detail is
            // opened, without rereading gigabytes during indexing.
            if boundedMetadataScan, !cwd.isEmpty, firstUserContent != nil, earliest != nil {
                return false
            }
            return true
        }

        let mtime = values.contentModificationDate ?? indexEntry?.updatedAt ?? Date()
        let countIsUnknown = !readResult.reachedEndOfFile || readResult.skippedOversizedLines > 0
        return DiscoveredSession(
            tool: toolId,
            toolSessionId: sessionId,
            sourcePath: file.path,
            projectCwd: cwd,
            startedAt: earliest ?? mtime,
            // The design contract defines updatedAt as source mtime so it can
            // participate in incremental-index decisions.
            updatedAt: mtime,
            messageCount: countIsUnknown ? -1 : messageCount,
            title: indexEntry?.title ?? firstUserContent.flatMap { SessionDisplayText.title(from: $0) },
            preview: firstUserContent ?? indexEntry?.title ?? ""
        )
    }

    private func parseDetail(at file: URL, sessionId: String) throws -> SessionDetail {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()
        var cwd = ""
        var messages: [SessionMessage] = []
        var earliest: Date?
        var totalCharacters = 0
        var hitBudget = false
        var truncatedContent = false

        func appendMessage(
            role: MessageRole,
            content: String,
            timestamp: Date,
            toolName: String? = nil,
            toolInput: String? = nil
        ) {
            guard messages.count < Self.detailMessageLimit,
                  totalCharacters < Self.detailCharacterLimit else {
                hitBudget = true
                return
            }
            let allowed = min(
                Self.perMessageCharacterLimit,
                Self.detailCharacterLimit - totalCharacters
            )
            let clipped = String(content.prefix(allowed))
            if clipped.count < content.count { truncatedContent = true }
            messages.append(SessionMessage(
                role: role,
                content: clipped,
                timestamp: timestamp,
                toolName: toolName,
                toolInput: toolInput.map { String($0.prefix(allowed)) }
            ))
            totalCharacters += clipped.count
            if messages.count >= Self.detailMessageLimit || totalCharacters >= Self.detailCharacterLimit {
                hitBudget = true
            }
        }

        let readResult = try JSONLStreamReader.forEachLine(
            at: file,
            byteLimit: Self.detailScanBytes
        ) { lineData in
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return !hitBudget
            }
            if let payload = obj["payload"] {
                if let c = payload as? String, !c.isEmpty, c.hasPrefix("/") { cwd = c }
                else if let payloadObj = payload as? [String: Any] {
                    if let c = payloadObj["cwd"] as? String, !c.isEmpty { cwd = c }
                    if let role = payloadObj["role"] as? String,
                       role == "user" || role == "assistant" {
                        let rawContent = payloadObj["content"]
                        let msgRole: MessageRole = (role == "assistant") ? .assistant : .user
                        let ts = (obj["timestamp"] as? String)
                            .flatMap { parseDate($0, fractional: iso, plain: noFrac) } ?? Date()
                        if earliest == nil || ts < earliest! { earliest = ts }
                        if let content = SessionContentExtractor.text(from: rawContent) {
                            if msgRole == .user {
                                if let display = SessionDisplayText.cleanedUserText(content) {
                                    appendMessage(role: msgRole, content: display, timestamp: ts)
                                }
                            } else {
                                appendMessage(role: msgRole, content: content, timestamp: ts)
                            }
                        }
                        if msgRole == .assistant {
                            for block in SessionContentExtractor.toolUseBlocks(from: rawContent) {
                                appendMessage(
                                    role: .tool,
                                    content: block.input,
                                    timestamp: ts,
                                    toolName: block.name,
                                    toolInput: block.input
                                )
                                if hitBudget { break }
                            }
                        }
                    }
                }
            }
            return !hitBudget
        }
        return SessionDetail(
            tool: toolId,
            toolSessionId: sessionId,
            cwd: cwd,
            startedAt: earliest ?? Date(),
            messages: messages,
            isTruncated: hitBudget || truncatedContent || !readResult.reachedEndOfFile
                || readResult.skippedOversizedLines > 0
        )
    }

    private func readSessionIndex() -> [String: SessionIndexEntry] {
        let url = rootURL.appendingPathComponent("session_index.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let noFrac = ISO8601DateFormatter()
        var entries: [String: SessionIndexEntry] = [:]
        _ = try? JSONLStreamReader.forEachLine(at: url) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? String else { return true }
            let title = (object["thread_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let updatedAt = (object["updated_at"] as? String)
                .flatMap { parseDate($0, fractional: iso, plain: noFrac) }
            entries[id] = SessionIndexEntry(title: title, updatedAt: updatedAt)
            return true
        }
        return entries
    }

    private func parseDate(
        _ value: String,
        fractional: ISO8601DateFormatter,
        plain: ISO8601DateFormatter
    ) -> Date? {
        fractional.date(from: value) ?? plain.date(from: value)
    }

    private func findFile(forSessionId sid: String) -> URL? {
        let sessionsRoot = rootURL.appendingPathComponent("sessions", isDirectory: true)
        let archRoot = rootURL.appendingPathComponent("archived_sessions", isDirectory: true)
        for root in [sessionsRoot, archRoot] where FileManager.default.fileExists(atPath: root.path) {
            if let f = findIn(dir: root, sessionId: sid) { return f }
        }
        return nil
    }

    private func findIn(dir: URL, sessionId: String) -> URL? {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in contents {
            if let isDir = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir {
                if let f = findIn(dir: item, sessionId: sessionId) { return f }
            } else if item.pathExtension == "jsonl" && extractSessionId(from: item) == sessionId {
                return item
            }
        }
        return nil
    }
}
