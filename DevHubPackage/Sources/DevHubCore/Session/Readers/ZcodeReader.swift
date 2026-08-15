import Foundation

/// zcode 会话 reader（spec §5.3）。
///
/// 数据源：`~/.zcode/cli/rollout/model-io-sess_*.jsonl`（跳过 `subagent_`）。
/// cwd 处理：rollout 顶层无 cwd 字段（已核验），本 reader **不推断 cwd**——返回空串，
/// 由 `ZcodeCwdBinder` 让用户手动绑定（误用 artifacts 路径会污染项目归集）。
public struct ZcodeReader: SessionReader {
    public let toolId = "zcode"
    public let rootDir: URL

    private static let fullMetadataScanThreshold = 1 * 1_024 * 1_024
    private static let quickMetadataScanBytes: UInt64 = 4 * 1_024 * 1_024
    private static let metadataTailScanBytes: UInt64 = 12 * 1_024 * 1_024
    private static let detailTailScanBytes: UInt64 = 16 * 1_024 * 1_024
    private static let detailMessageLimit = 500
    private static let detailCharacterLimit = 2_000_000
    private static let perMessageCharacterLimit = 50_000

    public init(rootDir: URL? = nil) {
        if let rootDir {
            self.rootDir = rootDir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.rootDir = home.appendingPathComponent(".zcode/cli")
        }
    }

    private var rolloutDir: URL { rootDir.appendingPathComponent("rollout") }

    public func discover() async throws -> [DiscoveredSession] {
        try await discover(knownFiles: [:])
    }

    public func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: rolloutDir.path) else { return [] }
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? fm.contentsOfDirectory(
            at: rolloutDir,
            includingPropertiesForKeys: Array(keys)
        )) ?? []
        var normalizedKnownFiles: [String: Date] = [:]
        for (path, indexedAt) in knownFiles {
            let normalized = JSONLStreamReader.canonicalPath(path)
            normalizedKnownFiles[normalized] = max(
                normalizedKnownFiles[normalized] ?? .distantPast,
                indexedAt
            )
        }
        var result: [DiscoveredSession] = []
        for file in files where file.pathExtension == "jsonl" {
            let name = file.lastPathComponent
            // 跳过 subagent（与 Claude 一致）
            if name.contains("subagent_") { continue }
            // 仅处理 model-io-sess_<uuid>.jsonl
            guard name.hasPrefix("model-io-sess_") else { continue }
            let values = try? file.resourceValues(forKeys: keys)
            let mtime = values?.contentModificationDate ?? .distantPast
            let canonicalPath = JSONLStreamReader.canonicalPath(file.path)
            if let indexedAt = normalizedKnownFiles[canonicalPath], indexedAt >= mtime {
                continue
            }
            guard let session = try? parseSession(at: file, values: values) else { continue }
            result.append(session)
        }
        return result
    }

    public func load(_ id: String) async throws -> SessionDetail {
        let file = rolloutDir.appendingPathComponent("model-io-\(id).jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw NSError(domain: "notFound", code: 404)
        }
        return try parseDetail(at: file, sessionId: id)
    }

    private func parseSession(
        at file: URL,
        values providedValues: URLResourceValues? = nil
    ) throws -> DiscoveredSession {
        let sessionId = sessionId(from: file.lastPathComponent)
        let values = try providedValues ?? file.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        )
        let fileSize = values.fileSize ?? 0
        let boundedMetadataScan = fileSize > Self.fullMetadataScanThreshold
        let mtime = values.contentModificationDate ?? Date()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        var earliest: Date?
        var firstUserContent: String?
        var latestConversationCount = 0
        var eventCount = 0

        let headReadResult = try JSONLStreamReader.forEachLine(
            at: file,
            byteLimit: boundedMetadataScan ? Self.quickMetadataScanBytes : nil
        ) { lineData in
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return true
            }
            eventCount += 1
            if let rawDate = obj["startedAt"] as? String,
               let date = parseDate(rawDate, fractional: fractional, plain: plain),
               earliest == nil || date < earliest! {
                earliest = date
            }
            if let messages = requestMessages(in: obj), !messages.isEmpty {
                latestConversationCount = messages.count
                if firstUserContent == nil {
                    firstUserContent = firstDisplayableUserText(in: messages)
                }
            }
            if boundedMetadataScan, earliest != nil, firstUserContent != nil {
                return false
            }
            return true
        }

        // ZCode may not persist a human message until a late request snapshot.
        // A bounded tail pass finds it without walking the bytes between the
        // head metadata and the latest complete request.
        var tailReadResult: JSONLStreamReader.ReadResult?
        if boundedMetadataScan, firstUserContent == nil {
            let tailOffset = JSONLStreamReader.tailOffset(
                for: file,
                maximumBytes: Self.metadataTailScanBytes
            )
            tailReadResult = try JSONLStreamReader.forEachLine(
                at: file,
                startingAtOffset: tailOffset
            ) { lineData in
                guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let messages = requestMessages(in: obj),
                      !messages.isEmpty else { return true }
                latestConversationCount = messages.count
                if let display = firstDisplayableUserText(in: messages) {
                    firstUserContent = display
                }
                return true
            }
        }

        let countIsUnknown = boundedMetadataScan
            || !headReadResult.reachedEndOfFile
            || headReadResult.skippedOversizedLines > 0
            || (tailReadResult?.skippedOversizedLines ?? 0) > 0
        let exactCount = latestConversationCount > 0 ? latestConversationCount : eventCount
        return DiscoveredSession(
            tool: toolId,
            toolSessionId: sessionId,
            sourcePath: file.path,
            projectCwd: "",  // 关键：rollout 无 cwd，由 ZcodeCwdBinder 用户绑定
            startedAt: earliest ?? mtime,
            updatedAt: mtime,
            messageCount: countIsUnknown ? -1 : exactCount,
            title: firstUserContent.flatMap { SessionDisplayText.title(from: $0) },
            preview: firstUserContent ?? ""
        )
    }

    /// 从文件名 `model-io-sess_<uuid>.jsonl` 抽 `sess_<uuid>`。
    private func sessionId(from filename: String) -> String {
        let name = (filename as NSString).deletingPathExtension
        if let range = name.range(of: "sess_") {
            return String(name[range.lowerBound...])
        }
        return name
    }

    /// ZCode records the complete request history on every model call. The
    /// newest request is therefore the source of truth for detail display;
    /// concatenating every record duplicates the conversation many times.
    private func parseDetail(at file: URL, sessionId: String) throws -> SessionDetail {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
        let mtime = values.contentModificationDate ?? Date()

        var earliest: Date?
        _ = try JSONLStreamReader.forEachLine(
            at: file,
            byteLimit: Self.quickMetadataScanBytes
        ) { lineData in
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let rawDate = obj["startedAt"] as? String,
                  let date = parseDate(rawDate, fractional: fractional, plain: plain) else {
                return true
            }
            earliest = date
            return false
        }

        let tailOffset = JSONLStreamReader.tailOffset(
            for: file,
            maximumBytes: Self.detailTailScanBytes
        )
        var latestRawMessages: [[String: Any]] = []
        var latestTimestamp = mtime
        var latestResponseText: String?
        let readResult = try JSONLStreamReader.forEachLine(
            at: file,
            startingAtOffset: tailOffset
        ) { lineData in
            guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                return true
            }
            guard let requestMessages = requestMessages(in: obj), !requestMessages.isEmpty else {
                return true
            }
            latestRawMessages = requestMessages
            if let rawDate = obj["startedAt"] as? String,
               let date = parseDate(rawDate, fractional: fractional, plain: plain) {
                latestTimestamp = date
            }
            if let response = obj["response"] as? [String: Any] {
                latestResponseText = SessionContentExtractor.text(
                    from: response["text"] ?? response["content"]
                )
            } else {
                latestResponseText = nil
            }
            return true
        }

        var firstUser: (index: Int, content: String)?
        for index in latestRawMessages.indices {
            let raw = latestRawMessages[index]
            guard (raw["role"] as? String)?.lowercased() == "user",
                  let extracted = SessionContentExtractor.text(from: raw["content"]),
                  let display = SessionDisplayText.cleanedUserText(extracted) else { continue }
            firstUser = (index, display)
            break
        }

        var contentWasClipped = false
        let reservedFirstUserCharacters = min(
            firstUser?.content.count ?? 0,
            Self.perMessageCharacterLimit
        )
        let recentLimit = max(0, Self.detailMessageLimit - (firstUser == nil ? 0 : 1))
        var recentCharacters = 0
        var recent: [(index: Int, message: SessionMessage)] = []

        for index in latestRawMessages.indices.reversed() {
            if recent.count >= recentLimit { break }
            let remaining = Self.detailCharacterLimit
                - reservedFirstUserCharacters
                - recentCharacters
            if remaining <= 0 { break }
            guard let decoded = decodedMessage(from: latestRawMessages[index]) else { continue }
            let allowed = min(Self.perMessageCharacterLimit, remaining)
            let clipped = String(decoded.content.prefix(allowed))
            if clipped.count < decoded.content.count { contentWasClipped = true }
            recent.append((
                index,
                SessionMessage(
                    role: decoded.role,
                    content: clipped,
                    timestamp: latestTimestamp
                )
            ))
            recentCharacters += clipped.count
        }

        recent.reverse()
        var messages = recent.map(\.message)
        let selectedIndices = Set(recent.map(\.index))
        if let firstUser, !selectedIndices.contains(firstUser.index) {
            let clipped = String(firstUser.content.prefix(Self.perMessageCharacterLimit))
            if clipped.count < firstUser.content.count { contentWasClipped = true }
            messages.insert(
                SessionMessage(role: .user, content: clipped, timestamp: latestTimestamp),
                at: 0
            )
        }

        var totalCharacters = messages.reduce(0) { $0 + $1.content.count }
        if let latestResponseText,
           messages.count < Self.detailMessageLimit,
           totalCharacters < Self.detailCharacterLimit {
            let allowed = min(
                Self.perMessageCharacterLimit,
                Self.detailCharacterLimit - totalCharacters
            )
            let clipped = String(latestResponseText.prefix(allowed))
            if clipped.count < latestResponseText.count { contentWasClipped = true }
            messages.append(SessionMessage(
                role: .assistant,
                content: clipped,
                timestamp: latestTimestamp
            ))
            totalCharacters += clipped.count
        }

        return SessionDetail(
            tool: toolId,
            toolSessionId: sessionId,
            cwd: "",
            startedAt: earliest ?? mtime,
            messages: messages,
            isTruncated: tailOffset > 0
                || latestRawMessages.count > Self.detailMessageLimit
                || contentWasClipped
                || !readResult.reachedEndOfFile
                || readResult.skippedOversizedLines > 0
        )
    }

    private func requestMessages(in object: [String: Any]) -> [[String: Any]]? {
        let request = object["request"] as? [String: Any]
        let body = request?["body"] as? [String: Any]
        return body?["messages"] as? [[String: Any]]
    }

    private func firstDisplayableUserText(in messages: [[String: Any]]) -> String? {
        for message in messages {
            guard (message["role"] as? String)?.lowercased() == "user",
                  let content = SessionContentExtractor.text(from: message["content"]),
                  let display = SessionDisplayText.preview(from: content) else { continue }
            return display
        }
        return nil
    }

    private func decodedMessage(
        from raw: [String: Any]
    ) -> (role: MessageRole, content: String)? {
        let rawRole = (raw["role"] as? String)?.lowercased() ?? ""
        let role: MessageRole
        switch rawRole {
        case "user": role = .user
        case "assistant": role = .assistant
        case "tool": role = .tool
        default: return nil
        }
        guard let extracted = SessionContentExtractor.text(from: raw["content"]) else {
            return nil
        }
        if role == .user {
            guard let display = SessionDisplayText.cleanedUserText(extracted) else { return nil }
            return (role, display)
        }
        return (role, extracted)
    }

    private func parseDate(
        _ raw: String,
        fractional: ISO8601DateFormatter,
        plain: ISO8601DateFormatter
    ) -> Date? {
        fractional.date(from: raw) ?? plain.date(from: raw)
    }
}
