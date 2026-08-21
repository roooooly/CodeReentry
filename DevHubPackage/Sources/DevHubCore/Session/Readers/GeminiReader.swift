import Foundation

/// Bounded, read-only reader for Gemini CLI's project-scoped JSONL sessions.
///
/// Current Gemini CLI stores sessions under
/// `~/.gemini/tmp/<project-id>/chats/session-*.jsonl`. The project root comes
/// from the official `projects.json` registry or the `.project_root` ownership
/// marker; the opaque directory name and `projectHash` are never guessed.
public struct GeminiReader: SessionReader {
    public let toolId = "gemini-cli"
    public let geminiRoot: URL

    private static let projectDirectoryLimit = 100
    private static let sessionFileLimit = 1_000
    private static let fullMetadataScanThreshold = 1 * 1_024 * 1_024
    private static let metadataScanBytes: UInt64 = 2 * 1_024 * 1_024
    private static let detailScanBytes: UInt64 = 64 * 1_024 * 1_024
    private static let maximumLineBytes = 1 * 1_024 * 1_024
    private static let detailMessageLimit = 500
    private static let detailCharacterLimit = 2_000_000
    private static let perMessageCharacterLimit = 50_000
    private static let markerByteLimit = 64 * 1_024

    private let maxProjectDirectories: Int
    private let maxSessionFiles: Int

    public init(
        geminiRoot: URL? = nil,
        homeURL: URL? = nil,
        maxProjectDirectories: Int = 100,
        maxSessionFiles: Int = 1_000
    ) {
        let home = homeURL ?? FileManager.default.homeDirectoryForCurrentUser
        self.geminiRoot = geminiRoot ?? home.appendingPathComponent(".gemini", isDirectory: true)
        self.maxProjectDirectories = min(
            max(1, maxProjectDirectories),
            Self.projectDirectoryLimit
        )
        self.maxSessionFiles = min(max(1, maxSessionFiles), Self.sessionFileLimit)
    }

    public func discover() async throws -> [DiscoveredSession] {
        try await discover(knownFiles: [:])
    }

    public func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession] {
        let candidates = try sessionCandidates()
        var normalizedKnownFiles: [String: Date] = [:]
        for (path, indexedAt) in knownFiles {
            let normalized = JSONLStreamReader.canonicalPath(path)
            normalizedKnownFiles[normalized] = max(
                normalizedKnownFiles[normalized] ?? .distantPast,
                indexedAt
            )
        }

        var sessions: [DiscoveredSession] = []
        for candidate in candidates {
            try Task.checkCancellation()
            let sourcePath = JSONLStreamReader.canonicalPath(candidate.file.path)
            if let indexedAt = normalizedKnownFiles[sourcePath], indexedAt >= candidate.modifiedAt {
                continue
            }
            if let session = try? parseMetadata(candidate, sourcePath: sourcePath) {
                sessions.append(session)
            }
        }
        return sessions
    }

    public func load(_ id: String) async throws -> SessionDetail {
        for candidate in try sessionCandidates() {
            try Task.checkCancellation()
            if try metadataSessionId(at: candidate.file) == id {
                return try parseDetail(candidate, sessionId: id)
            }
        }
        throw GeminiReaderError.sessionNotFound(id)
    }

    private struct Candidate: Sendable {
        let file: URL
        let projectRoot: String
        let modifiedAt: Date
    }

    private func sessionCandidates() throws -> [Candidate] {
        let fileManager = FileManager.default
        let temporaryRoot = geminiRoot.appendingPathComponent("tmp", isDirectory: true)
        guard fileManager.fileExists(atPath: temporaryRoot.path) else { return [] }

        let registry = readProjectRegistry()
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey
        ]
        let projectDirectories = ((try? fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: keys).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maxProjectDirectories)

        var candidates: [Candidate] = []
        for directory in projectDirectories {
            try Task.checkCancellation()
            guard let projectRoot = projectRoot(for: directory, registry: registry) else { continue }
            let chats = directory.appendingPathComponent("chats", isDirectory: true)
            let files = (try? fileManager.contentsOfDirectory(
                at: chats,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where file.pathExtension == "jsonl"
                && file.lastPathComponent.hasPrefix("session-") {
                let values = try? file.resourceValues(forKeys: keys)
                guard values?.isRegularFile == true else { continue }
                candidates.append(Candidate(
                    file: file,
                    projectRoot: projectRoot,
                    modifiedAt: values?.contentModificationDate ?? .distantPast
                ))
            }
        }

        return candidates
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.file.path < $1.file.path
            }
            .prefix(maxSessionFiles)
            .map { $0 }
    }

    private func readProjectRegistry() -> [String: String] {
        let url = geminiRoot.appendingPathComponent("projects.json")
        guard let data = readSmallData(at: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: String] else { return [:] }
        var inverse: [String: String] = [:]
        for (path, identifier) in projects where !path.isEmpty && !identifier.isEmpty {
            inverse[identifier] = (path as NSString).standardizingPath
        }
        return inverse
    }

    private func projectRoot(for directory: URL, registry: [String: String]) -> String? {
        let marker = directory.appendingPathComponent(".project_root")
        if let value = readSmallString(at: marker) {
            return (value as NSString).standardizingPath
        }
        return registry[directory.lastPathComponent]
    }

    private func readSmallString(at url: URL) -> String? {
        guard let data = readSmallData(at: url),
              let value = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    private func readSmallData(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.markerByteLimit + 1),
              data.count <= Self.markerByteLimit else { return nil }
        return data
    }

    private func parseMetadata(_ candidate: Candidate, sourcePath: String) throws -> DiscoveredSession {
        var sessionId: String?
        var startTime: Date?
        var kind: String?
        var firstUserContent: String?
        var messageIds: [String] = []
        var resumableMessageIds = Set<String>()
        let values = try candidate.file.resourceValues(forKeys: [.fileSizeKey])
        let bounded = (values.fileSize ?? 0) > Self.fullMetadataScanThreshold

        let result = try JSONLStreamReader.forEachLine(
            at: candidate.file,
            byteLimit: bounded ? Self.metadataScanBytes : nil,
            maximumLineBytes: Self.maximumLineBytes
        ) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                return true
            }
            if sessionId == nil, let value = Self.nonEmptyString(object["sessionId"]) {
                sessionId = value
                startTime = Self.date(object["startTime"])
                kind = object["kind"] as? String
            }
            if let type = object["type"] as? String, type == "user" || type == "gemini",
               let messageId = Self.nonEmptyString(object["id"]) {
                messageIds.append(messageId)
                if SessionContentExtractor.text(from: object["content"]) != nil {
                    resumableMessageIds.insert(messageId)
                }
                if type == "user", firstUserContent == nil,
                   let content = SessionContentExtractor.text(from: object["content"]),
                   let display = SessionDisplayText.preview(from: content) {
                    firstUserContent = display
                }
            } else if let rewindTo = Self.nonEmptyString(object["$rewindTo"]) {
                if let index = messageIds.firstIndex(of: rewindTo) {
                    for id in messageIds[index...] { resumableMessageIds.remove(id) }
                    messageIds.removeSubrange(index...)
                } else {
                    messageIds.removeAll()
                    resumableMessageIds.removeAll()
                }
            } else if let set = object["$set"] as? [String: Any] {
                if let updatedSessionId = Self.nonEmptyString(set["sessionId"]) {
                    sessionId = updatedSessionId
                }
                if let updatedStartTime = Self.date(set["startTime"]) {
                    startTime = updatedStartTime
                }
                if let updatedKind = set["kind"] as? String { kind = updatedKind }
                if let messages = set["messages"] as? [[String: Any]] {
                    messageIds.removeAll()
                    resumableMessageIds.removeAll()
                    for message in messages {
                        guard let messageId = Self.nonEmptyString(message["id"]),
                              let type = message["type"] as? String,
                              type == "user" || type == "gemini" else { continue }
                        messageIds.append(messageId)
                        if SessionContentExtractor.text(from: message["content"]) != nil {
                            resumableMessageIds.insert(messageId)
                        }
                        if type == "user", firstUserContent == nil,
                           let content = SessionContentExtractor.text(from: message["content"]),
                           let display = SessionDisplayText.preview(from: content) {
                            firstUserContent = display
                        }
                    }
                }
            }
            if bounded, sessionId != nil, startTime != nil, firstUserContent != nil {
                return false
            }
            return true
        }

        guard let sessionId else { throw GeminiReaderError.invalidSession(candidate.file.path) }
        guard kind != "subagent" else { throw GeminiReaderError.subagentSession }
        let countUnknown = !result.reachedEndOfFile || result.skippedOversizedLines > 0
        let title = firstUserContent.flatMap { SessionDisplayText.title(from: $0) }
        return DiscoveredSession(
            tool: toolId,
            toolSessionId: sessionId,
            sourcePath: sourcePath,
            projectCwd: candidate.projectRoot,
            startedAt: startTime ?? candidate.modifiedAt,
            updatedAt: candidate.modifiedAt,
            messageCount: countUnknown ? -1 : resumableMessageIds.count,
            title: title,
            preview: firstUserContent ?? ""
        )
    }

    private func metadataSessionId(at file: URL) throws -> String? {
        var sessionId: String?
        _ = try JSONLStreamReader.forEachLine(
            at: file,
            byteLimit: 256 * 1_024,
            maximumLineBytes: Self.maximumLineBytes
        ) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let value = Self.nonEmptyString(object["sessionId"]) else { return true }
            sessionId = value
            return false
        }
        return sessionId
    }

    private struct ParsedMessage {
        let id: String
        let message: SessionMessage
    }

    private func parseDetail(_ candidate: Candidate, sessionId: String) throws -> SessionDetail {
        var parsed: [ParsedMessage] = []
        var startedAt: Date?
        var totalCharacters = 0
        var hitBudget = false
        var truncatedContent = false

        func append(_ object: [String: Any]) {
            guard let id = Self.nonEmptyString(object["id"]),
                  let type = object["type"] as? String,
                  type == "user" || type == "gemini" else { return }
            let timestamp = Self.date(object["timestamp"]) ?? startedAt ?? candidate.modifiedAt
            let role: MessageRole = type == "user" ? .user : .assistant
            if let content = SessionContentExtractor.text(from: object["content"]) {
                let display = role == .user
                    ? SessionDisplayText.cleanedUserText(content)
                    : content
                if let display, !display.isEmpty {
                    appendParsed(id: id, role: role, content: display, timestamp: timestamp)
                }
            }
            guard role == .assistant, let toolCalls = object["toolCalls"] as? [[String: Any]] else {
                return
            }
            for call in toolCalls {
                guard let name = Self.nonEmptyString(call["name"]) else { continue }
                let input = Self.jsonString(call["args"]) ?? ""
                appendParsed(
                    id: "\(id):tool:\(parsed.count)",
                    role: .tool,
                    content: input,
                    timestamp: Self.date(call["timestamp"]) ?? timestamp,
                    toolName: name,
                    toolInput: input
                )
                if hitBudget { break }
            }
        }

        func appendParsed(
            id: String,
            role: MessageRole,
            content: String,
            timestamp: Date,
            toolName: String? = nil,
            toolInput: String? = nil
        ) {
            guard parsed.count < Self.detailMessageLimit,
                  totalCharacters < Self.detailCharacterLimit else {
                hitBudget = true
                return
            }
            let allowed = min(Self.perMessageCharacterLimit, Self.detailCharacterLimit - totalCharacters)
            let clipped = String(content.prefix(allowed))
            if clipped.count < content.count { truncatedContent = true }
            parsed.append(ParsedMessage(
                id: id,
                message: SessionMessage(
                    role: role,
                    content: clipped,
                    timestamp: timestamp,
                    toolName: toolName,
                    toolInput: toolInput.map { String($0.prefix(allowed)) }
                )
            ))
            totalCharacters += clipped.count
            if parsed.count >= Self.detailMessageLimit || totalCharacters >= Self.detailCharacterLimit {
                hitBudget = true
            }
        }

        let result = try JSONLStreamReader.forEachLine(
            at: candidate.file,
            byteLimit: Self.detailScanBytes,
            maximumLineBytes: Self.maximumLineBytes
        ) { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                return !hitBudget
            }
            if let metadataId = Self.nonEmptyString(object["sessionId"]), metadataId == sessionId {
                startedAt = Self.date(object["startTime"]) ?? startedAt
            } else if let rewindTo = Self.nonEmptyString(object["$rewindTo"]) {
                if let index = parsed.firstIndex(where: { $0.id == rewindTo }) {
                    parsed.removeSubrange(index...)
                    totalCharacters = parsed.reduce(0) { $0 + $1.message.content.count }
                } else {
                    parsed.removeAll()
                    totalCharacters = 0
                }
            } else if let set = object["$set"] as? [String: Any],
                      let messages = set["messages"] as? [[String: Any]] {
                parsed.removeAll()
                totalCharacters = 0
                for message in messages {
                    append(message)
                    if hitBudget { break }
                }
            } else {
                append(object)
            }
            return !hitBudget
        }

        return SessionDetail(
            tool: toolId,
            toolSessionId: sessionId,
            cwd: candidate.projectRoot,
            startedAt: startedAt ?? candidate.modifiedAt,
            messages: parsed.map(\.message),
            isTruncated: hitBudget || truncatedContent || !result.reachedEndOfFile
                || result.skippedOversizedLines > 0
        )
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private static func jsonString(_ value: Any?) -> String? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }
}

public enum GeminiReaderError: LocalizedError, Sendable, Equatable {
    case invalidSession(String)
    case sessionNotFound(String)
    case subagentSession

    public var errorDescription: String? {
        switch self {
        case .invalidSession(let path):
            return "Gemini CLI 会话格式无效：\(path)"
        case .sessionNotFound(let id):
            return "未找到 Gemini CLI 会话：\(id)"
        case .subagentSession:
            return "Gemini CLI 子代理会话不作为独立可恢复会话显示。"
        }
    }
}
