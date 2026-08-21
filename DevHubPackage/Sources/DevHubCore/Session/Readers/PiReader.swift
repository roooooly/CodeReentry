import Foundation

/// Bounded, read-only access to Pi v0.84.2 JSONL sessions.
///
/// Pi stores project sessions below `~/.pi/agent/sessions/` by default. An
/// absolute `PI_CODING_AGENT_SESSION_DIR` selects one shared custom directory.
/// Discovery reads only file metadata and the JSONL header. Conversation text
/// is decoded on demand, follows Pi's active parent chain, and excludes images,
/// thinking, tool calls/results, extension messages, and summaries.
public struct PiReader: SessionReader {
    public let toolId = "pi"

    private static let sessionHardLimit = 1_000
    private static let directoryEntryHardLimit = 10_000
    private static let headerByteHardLimit: UInt64 = 1 * 1_024 * 1_024
    private static let detailByteHardLimit: UInt64 = 64 * 1_024 * 1_024
    private static let lineByteHardLimit = 1 * 1_024 * 1_024
    private static let entryHardLimit = 100_000
    private static let messageHardLimit = 500
    private static let characterHardLimit = 2_000_000
    private static let perMessageCharacterLimit = 50_000
    private static let pathByteLimit = 32_768
    private static let identifierByteLimit = 4_096

    private let sessionRoot: URL
    private let maxSessions: Int
    private let maxDetailBytes: UInt64
    private let maxLineBytes: Int
    private let maxEntries: Int
    private let maxMessages: Int
    private let maxCharacters: Int

    public init(
        sessionRoot: URL? = nil,
        homeURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxSessions: Int = 1_000,
        maxDetailBytes: UInt64 = 64 * 1_024 * 1_024,
        maxLineBytes: Int = 1 * 1_024 * 1_024,
        maxEntries: Int = 100_000,
        maxMessages: Int = 500,
        maxCharacters: Int = 2_000_000
    ) {
        let home = homeURL ?? FileManager.default.homeDirectoryForCurrentUser
        self.sessionRoot = sessionRoot ?? Self.standardSessionRoot(
            homeURL: home, environment: environment
        )
        self.maxSessions = min(max(1, maxSessions), Self.sessionHardLimit)
        self.maxDetailBytes = min(max(1, maxDetailBytes), Self.detailByteHardLimit)
        self.maxLineBytes = min(max(1, maxLineBytes), Self.lineByteHardLimit)
        self.maxEntries = min(max(1, maxEntries), Self.entryHardLimit)
        self.maxMessages = min(max(1, maxMessages), Self.messageHardLimit)
        self.maxCharacters = min(max(1, maxCharacters), Self.characterHardLimit)
    }

    public func discover() async throws -> [DiscoveredSession] {
        try await discover(knownFiles: [:])
    }

    public func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession] {
        let normalizedKnown = Dictionary(grouping: knownFiles.keys) {
            JSONLStreamReader.canonicalPath($0)
        }.compactMapValues { paths in paths.compactMap { knownFiles[$0] }.max() }

        var sessions: [DiscoveredSession] = []
        for candidate in try candidates() {
            try Task.checkCancellation()
            if let indexedAt = normalizedKnown[candidate.path], indexedAt >= candidate.modifiedAt {
                continue
            }
            guard let header = try readHeader(candidate.url) else { continue }
            let title = "Pi \(String(header.id.prefix(12)))"
            sessions.append(DiscoveredSession(
                tool: toolId,
                toolSessionId: candidate.path,
                sourcePath: candidate.path,
                projectCwd: header.cwd,
                startedAt: header.timestamp,
                updatedAt: candidate.modifiedAt,
                messageCount: -1,
                title: title,
                preview: title
            ))
        }
        return sessions.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.toolSessionId < $1.toolSessionId
        }
    }

    public func load(_ id: String) async throws -> SessionDetail {
        try Task.checkCancellation()
        guard !id.isEmpty, id.utf8.count <= Self.pathByteLimit else {
            throw PiReaderError.sessionNotFound(id)
        }
        let target = JSONLStreamReader.canonicalPath(id)
        guard let candidate = try candidates().first(where: { $0.path == target }) else {
            throw PiReaderError.sessionNotFound(id)
        }
        guard candidate.size <= maxDetailBytes else {
            throw PiReaderError.fileTooLarge(candidate.path, maxDetailBytes)
        }

        var header: Header?
        var entries: [String: Entry] = [:]
        var order: [String] = []
        var malformed = false
        let result = try JSONLStreamReader.forEachLine(
            at: candidate.url,
            byteLimit: maxDetailBytes,
            maximumLineBytes: maxLineBytes
        ) { data in
            try Task.checkCancellation()
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = object["type"] as? String else {
                malformed = true
                return true
            }
            if header == nil {
                guard type == "session", let parsed = Self.header(from: object) else {
                    throw PiReaderError.malformedSession(candidate.path)
                }
                header = parsed
                return true
            }
            guard let entryID = Self.boundedString(
                object["id"], byteLimit: Self.identifierByteLimit
            ) else {
                malformed = true
                return true
            }
            guard entries.count < maxEntries else {
                throw PiReaderError.tooManyEntries(candidate.path, maxEntries)
            }
            let parentID = Self.boundedString(
                object["parentId"], byteLimit: Self.identifierByteLimit
            )
            let timestamp = Self.date(object["timestamp"] as? String) ?? candidate.modifiedAt
            let message = type == "message" ? Self.visibleMessage(
                object["message"] as? [String: Any], timestamp: timestamp
            ) : nil
            if entries.updateValue(
                Entry(parentID: parentID, message: message), forKey: entryID
            ) != nil {
                malformed = true
            }
            order.append(entryID)
            return true
        }
        guard let header else { throw PiReaderError.malformedSession(candidate.path) }

        var active: [SessionMessage] = []
        var visited: Set<String> = []
        var cursor = order.last
        var brokenChain = false
        while let entryID = cursor {
            guard visited.insert(entryID).inserted else {
                brokenChain = true
                break
            }
            guard let entry = entries[entryID] else {
                brokenChain = true
                break
            }
            if let message = entry.message { active.append(message) }
            cursor = entry.parentID
        }
        active.reverse()

        var remainingCharacters = maxCharacters
        var retained: [SessionMessage] = []
        var truncated = malformed || brokenChain || result.skippedOversizedLines > 0
            || !result.reachedEndOfFile
        for message in active.reversed() {
            if retained.count >= maxMessages || remainingCharacters <= 0 {
                truncated = true
                break
            }
            let allowed = min(
                message.content.count,
                min(Self.perMessageCharacterLimit, remainingCharacters)
            )
            guard allowed > 0 else { continue }
            let content = String(message.content.prefix(allowed))
            if allowed < message.content.count { truncated = true }
            remainingCharacters -= allowed
            retained.append(SessionMessage(
                role: message.role, content: content, timestamp: message.timestamp
            ))
        }

        return SessionDetail(
            tool: toolId,
            toolSessionId: candidate.path,
            cwd: header.cwd,
            startedAt: header.timestamp,
            messages: Array(retained.reversed()),
            isTruncated: truncated || retained.count < active.count
        )
    }

    static func standardSessionRoot(
        homeURL: URL,
        environment: [String: String]
    ) -> URL {
        if let raw = environment["PI_CODING_AGENT_SESSION_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let expanded = (raw as NSString).expandingTildeInPath
            if (expanded as NSString).isAbsolutePath {
                return URL(fileURLWithPath: expanded, isDirectory: true)
            }
        }
        return homeURL.appendingPathComponent(".pi/agent/sessions", isDirectory: true)
    }

    private struct Candidate {
        let url: URL
        let path: String
        let modifiedAt: Date
        let size: UInt64
    }

    private struct Header {
        let id: String
        let cwd: String
        let timestamp: Date
    }

    private struct Entry {
        let parentID: String?
        let message: SessionMessage?
    }

    private func candidates() throws -> [Candidate] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: sessionRoot.path) else { return [] }
        try Self.requireSafeDirectory(sessionRoot)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey, .fileSizeKey
        ]
        let children = try manager.contentsOfDirectory(
            at: sessionRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        guard children.count <= Self.directoryEntryHardLimit else {
            throw PiReaderError.tooManyDirectoryEntries(sessionRoot.path)
        }

        var files: [URL] = []
        for child in children {
            try Task.checkCancellation()
            let values = try child.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true, child.pathExtension == "jsonl" {
                files.append(child)
            } else if values.isDirectory == true {
                let nested = try manager.contentsOfDirectory(
                    at: child,
                    includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles]
                )
                guard nested.count <= Self.directoryEntryHardLimit else {
                    throw PiReaderError.tooManyDirectoryEntries(child.path)
                }
                files.append(contentsOf: nested.filter { url in
                    guard url.pathExtension == "jsonl",
                          let values = try? url.resourceValues(forKeys: keys) else { return false }
                    return values.isRegularFile == true && values.isSymbolicLink != true
                })
            }
        }

        return try files.compactMap { url -> Candidate? in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            let path = JSONLStreamReader.canonicalPath(url.path)
            guard path.utf8.count <= Self.pathByteLimit else { return nil }
            return Candidate(
                url: url,
                path: path,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                size: UInt64(max(0, values.fileSize ?? 0))
            )
        }.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.path < $1.path
        }.prefix(maxSessions).map { $0 }
    }

    private func readHeader(_ url: URL) throws -> Header? {
        var parsed: Header?
        var sawLine = false
        let result = try JSONLStreamReader.forEachLine(
            at: url,
            byteLimit: Self.headerByteHardLimit,
            maximumLineBytes: maxLineBytes
        ) { data in
            sawLine = true
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["type"] as? String) == "session" else { return false }
            parsed = Self.header(from: object)
            return false
        }
        if sawLine && parsed == nil { return nil }
        if result.skippedOversizedLines > 0 { return nil }
        return parsed
    }

    private static func header(from object: [String: Any]) -> Header? {
        guard let id = boundedString(object["id"], byteLimit: identifierByteLimit),
              let cwd = boundedString(object["cwd"], byteLimit: pathByteLimit),
              (cwd as NSString).isAbsolutePath,
              let timestamp = date(object["timestamp"] as? String) else { return nil }
        return Header(id: id, cwd: cwd, timestamp: timestamp)
    }

    private static func visibleMessage(
        _ object: [String: Any]?, timestamp: Date
    ) -> SessionMessage? {
        guard let object, let roleRaw = object["role"] as? String else { return nil }
        let role: MessageRole
        switch roleRaw {
        case "user": role = .user
        case "assistant": role = .assistant
        default: return nil
        }
        let text: String
        if let raw = object["content"] as? String {
            text = raw
        } else if let blocks = object["content"] as? [[String: Any]] {
            text = blocks.compactMap { block in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: "\n\n")
        } else {
            return nil
        }
        guard !text.isEmpty else { return nil }
        let visible = role == .user ? SessionDisplayText.cleanedUserText(text) : text
        guard let visible, !visible.isEmpty else { return nil }
        return SessionMessage(role: role, content: visible, timestamp: timestamp)
    }

    private static func boundedString(_ value: Any?, byteLimit: Int) -> String? {
        guard let value = value as? String, !value.isEmpty,
              value.utf8.count <= byteLimit else { return nil }
        return value
    }

    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func requireSafeDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw PiReaderError.unsafeSessionRoot(url.path)
        }
    }
}

public enum PiReaderError: LocalizedError, Sendable, Equatable {
    case sessionNotFound(String)
    case unsafeSessionRoot(String)
    case malformedSession(String)
    case fileTooLarge(String, UInt64)
    case tooManyEntries(String, Int)
    case tooManyDirectoryEntries(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            "未找到 Pi 会话：\(id)"
        case .unsafeSessionRoot(let path):
            "拒绝扫描不安全的 Pi 会话目录：\(path)"
        case .malformedSession(let path):
            "Pi 会话格式无效：\(path)"
        case .fileTooLarge(let path, let limit):
            "Pi 会话文件超过安全读取上限：\(path)（\(limit) 字节）"
        case .tooManyEntries(let path, let limit):
            "Pi 会话条目超过安全解析上限：\(path)（\(limit) 条）"
        case .tooManyDirectoryEntries(let path):
            "Pi 会话目录条目过多，拒绝扫描：\(path)"
        }
    }
}
