import Foundation

/// Claude Code session reader（§5.3A）。
/// 扫描 `~/.claude/projects/<cwd-encoded>/<uuid>.jsonl`（跳过 subagents/）。
/// cwd 从 jsonl 内容读，不靠目录名反推。
public struct ClaudeReader: SessionReader {
    public let toolId = "claude-code"
    public let projectsRoot: URL

    private static let fullMetadataScanThreshold: Int = 1 * 1_024 * 1_024
    private static let quickMetadataScanBytes: UInt64 = 2 * 1_024 * 1_024
    private static let detailScanBytes: UInt64 = 64 * 1_024 * 1_024
    private static let detailMessageLimit = 500
    private static let detailCharacterLimit = 2_000_000
    private static let perMessageCharacterLimit = 50_000

    public init(projectsRoot: URL? = nil) {
        self.projectsRoot = projectsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude").appendingPathComponent("projects")
    }

    public func discover() async throws -> [DiscoveredSession] {
        try await discover(knownFiles: [:])
    }

    public func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession] {
        guard FileManager.default.fileExists(atPath: projectsRoot.path) else { return [] }
        var results: [DiscoveredSession] = []
        var normalizedKnownFiles: [String: Date] = [:]
        for (path, indexedAt) in knownFiles {
            let normalized = JSONLStreamReader.canonicalPath(path)
            normalizedKnownFiles[normalized] = max(
                normalizedKnownFiles[normalized] ?? .distantPast,
                indexedAt
            )
        }
        try walkJsonl(in: projectsRoot, knownFiles: normalizedKnownFiles, into: &results)
        return results
    }

    public func load(_ id: String) async throws -> SessionDetail {
        // 找到含此 sessionId 的文件
        guard let file = findFile(forSessionId: id) else {
            throw NSError(domain: "notFound", code: 404)
        }
        return try parseDetail(at: file, sessionId: id)
    }

    /// 递归遍历，收集所有 *.jsonl（跳过 subagents/）。
    /// 这样既支持 projectsRoot = ~/.claude/projects/（含 <encoded>/ 子目录），
    /// 也支持 projectsRoot = <encoded>/（直接含 jsonl，测试用）。
    private func walkJsonl(
        in dir: URL,
        knownFiles: [String: Date],
        into results: inout [DiscoveredSession]
    ) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Array(keys))) ?? []
        for item in contents {
            // v1 跳过 subagents 目录及其内部文件
            if item.lastPathComponent == "subagents" { continue }
            let values = try? item.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                try walkJsonl(in: item, knownFiles: knownFiles, into: &results)
            } else if item.pathExtension == "jsonl" {
                if item.path.contains("/subagents/") { continue }
                let mtime = values?.contentModificationDate ?? .distantPast
                let canonicalPath = JSONLStreamReader.canonicalPath(item.path)
                if let indexedAt = knownFiles[canonicalPath], indexedAt >= mtime { continue }
                if let discovered = try? parseJsonl(at: item) {
                    results.append(discovered)
                }
            }
        }
    }

    private func parseJsonl(at file: URL) throws -> DiscoveredSession {
        let sessionId = file.deletingPathExtension().lastPathComponent
        var cwd: String = ""
        var title: String?
        var firstUserContent: String?
        var messageCount = 0
        var earliestTs: Date?
        var latestTs: Date?

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
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            if obj["type"] as? String == "ai-title", let t = obj["title"] as? String { title = t }
            let type = obj["type"] as? String
            if type == "user" || type == "assistant" {
                let message = obj["message"] as? [String: Any]
                let content = SessionContentExtractor.text(from: message?["content"] ?? obj["content"])
                if content != nil { messageCount += 1 }
                if type == "user", firstUserContent == nil, let content,
                   let display = SessionDisplayText.preview(from: content) {
                    firstUserContent = display
                }
            }
            if let ts = obj["timestamp"] as? String,
               let date = parseDate(ts, fractional: iso, plain: noFrac) {
                if earliestTs == nil || date < earliestTs! { earliestTs = date }
                if latestTs == nil || date > latestTs! { latestTs = date }
            }
            if boundedMetadataScan, !cwd.isEmpty, firstUserContent != nil, earliestTs != nil {
                return false
            }
            return true
        }

        let mtime = values.contentModificationDate ?? Date()
        let countIsUnknown = !readResult.reachedEndOfFile || readResult.skippedOversizedLines > 0
        return DiscoveredSession(
            tool: toolId,
            toolSessionId: sessionId,
            sourcePath: file.path,
            projectCwd: cwd,
            startedAt: earliestTs ?? mtime,
            updatedAt: mtime,
            messageCount: countIsUnknown ? -1 : messageCount,
            title: title ?? firstUserContent.flatMap { SessionDisplayText.title(from: $0) },
            preview: firstUserContent ?? ""
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
            if let c = obj["cwd"] as? String, !c.isEmpty { cwd = c }
            let type = obj["type"] as? String
            if type == "user" || type == "assistant" {
                var role: MessageRole = .user
                if type == "assistant" { role = .assistant }
                let msg = obj["message"] as? [String: Any]
                let rawContent = msg?["content"] ?? obj["content"]
                let ts = (obj["timestamp"] as? String)
                    .flatMap { parseDate($0, fractional: iso, plain: noFrac) } ?? Date()
                if earliest == nil || ts < earliest! { earliest = ts }
                // 文本与工具调用分离：先抽纯文本（不含 tool_use），再单独抽工具块。
                if let content = SessionContentExtractor.text(from: rawContent) {
                    if role == .user {
                        if let display = SessionDisplayText.cleanedUserText(content) {
                            appendMessage(role: role, content: display, timestamp: ts)
                        }
                    } else {
                        appendMessage(role: role, content: content, timestamp: ts)
                    }
                }
                if role == .assistant {
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
            return !hitBudget
        }
        return SessionDetail(
            tool: toolId, toolSessionId: sessionId, cwd: cwd,
            startedAt: earliest ?? Date(), messages: messages,
            isTruncated: hitBudget || truncatedContent || !readResult.reachedEndOfFile
                || readResult.skippedOversizedLines > 0
        )
    }

    private func parseDate(
        _ value: String,
        fractional: ISO8601DateFormatter,
        plain: ISO8601DateFormatter
    ) -> Date? {
        fractional.date(from: value) ?? plain.date(from: value)
    }

    private func findFile(forSessionId sid: String) -> URL? {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in contents {
            if item.lastPathComponent == "subagents" { continue }
            if let isDir = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir {
                if let f = findIn(dir: item, sessionId: sid) { return f }
            } else if item.pathExtension == "jsonl" && item.deletingPathExtension().lastPathComponent == sid {
                return item
            }
        }
        return nil
    }

    private func findIn(dir: URL, sessionId: String) -> URL? {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in contents {
            if item.lastPathComponent == "subagents" { continue }
            if let isDir = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir {
                if let f = findIn(dir: item, sessionId: sessionId) { return f }
            } else if item.pathExtension == "jsonl" && item.deletingPathExtension().lastPathComponent == sessionId {
                return item
            }
        }
        return nil
    }
}
