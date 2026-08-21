import Foundation

/// Bounded, read-only reader for GitHub Copilot CLI session event logs.
///
/// Copilot CLI persists one session per directory under
/// `~/.copilot/session-state/<session-id>/events.jsonl`. This reader consumes
/// only the documented persisted event envelope and message/context payloads.
/// It excludes reasoning, system prompts, ephemeral deltas, and sub-agent
/// events from the conversation shown by CodeReentry.
public struct GitHubCopilotReader: SessionReader {
    public let toolId = "github-copilot"
    public let copilotRoot: URL

    private static let sessionDirectoryLimit = 1_000
    private static let fullMetadataScanThreshold = 1 * 1_024 * 1_024
    private static let metadataScanBytes: UInt64 = 2 * 1_024 * 1_024
    private static let detailScanBytes: UInt64 = 64 * 1_024 * 1_024
    private static let maximumLineBytes = 1 * 1_024 * 1_024
    private static let detailMessageLimit = 500
    private static let detailCharacterLimit = 2_000_000
    private static let perMessageCharacterLimit = 50_000

    private let maxSessionDirectories: Int

    public init(
        copilotRoot: URL? = nil,
        homeURL: URL? = nil,
        maxSessionDirectories: Int = 1_000
    ) {
        let home = homeURL ?? FileManager.default.homeDirectoryForCurrentUser
        self.copilotRoot = copilotRoot
            ?? home.appendingPathComponent(".copilot", isDirectory: true)
        self.maxSessionDirectories = min(
            max(1, maxSessionDirectories),
            Self.sessionDirectoryLimit
        )
    }

    public func discover() async throws -> [DiscoveredSession] {
        try await discover(knownFiles: [:])
    }

    public func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession] {
        var normalizedKnownFiles: [String: Date] = [:]
        for (path, indexedAt) in knownFiles {
            let normalized = JSONLStreamReader.canonicalPath(path)
            normalizedKnownFiles[normalized] = max(
                normalizedKnownFiles[normalized] ?? .distantPast,
                indexedAt
            )
        }

        var sessions: [DiscoveredSession] = []
        for candidate in try sessionCandidates() {
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
        guard let candidate = try sessionCandidates().first(where: { $0.sessionId == id }) else {
            throw GitHubCopilotReaderError.sessionNotFound(id)
        }
        return try parseDetail(candidate)
    }

    private struct Candidate: Sendable {
        let sessionId: String
        let file: URL
        let modifiedAt: Date
    }

    private func sessionCandidates() throws -> [Candidate] {
        let fileManager = FileManager.default
        let root = copilotRoot.appendingPathComponent("session-state", isDirectory: true)
        guard fileManager.fileExists(atPath: root.path) else { return [] }

        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        let directories = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []

        var candidates: [Candidate] = []
        for directory in directories {
            try Task.checkCancellation()
            let directoryValues = try? directory.resourceValues(forKeys: keys)
            guard directoryValues?.isDirectory == true,
                  directoryValues?.isSymbolicLink != true,
                  !directory.lastPathComponent.isEmpty else { continue }
            let file = directory.appendingPathComponent("events.jsonl", isDirectory: false)
            let fileValues = try? file.resourceValues(forKeys: keys)
            guard fileValues?.isRegularFile == true,
                  fileValues?.isSymbolicLink != true else { continue }
            candidates.append(Candidate(
                sessionId: directory.lastPathComponent,
                file: file,
                modifiedAt: fileValues?.contentModificationDate ?? .distantPast
            ))
        }

        return candidates
            .sorted {
                if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
                return $0.sessionId < $1.sessionId
            }
            .prefix(maxSessionDirectories)
            .map { $0 }
    }

    private func parseMetadata(
        _ candidate: Candidate,
        sourcePath: String
    ) throws -> DiscoveredSession {
        var projectCwd: String?
        var firstUserContent: String?
        var explicitTitle: String?
        var startedAt: Date?
        var messageCount = 0
        let values = try candidate.file.resourceValues(forKeys: [.fileSizeKey])
        let bounded = (values.fileSize ?? 0) > Self.fullMetadataScanThreshold

        let result = try JSONLStreamReader.forEachLine(
            at: candidate.file,
            byteLimit: bounded ? Self.metadataScanBytes : nil,
            maximumLineBytes: Self.maximumLineBytes
        ) { line in
            guard let event = Self.event(from: line) else { return true }
            if let timestamp = Self.date(event["timestamp"]),
               startedAt == nil || timestamp < startedAt! {
                startedAt = timestamp
            }
            guard event["agentId"] == nil,
                  let type = event["type"] as? String,
                  let data = event["data"] as? [String: Any] else { return true }

            switch type {
            case "session.context_changed":
                projectCwd = Self.projectPath(from: data) ?? projectCwd
            case "session.title_changed":
                explicitTitle = Self.nonEmptyString(data["title"]) ?? explicitTitle
            case "user.message":
                if let content = Self.nonEmptyString(data["content"]) {
                    messageCount += 1
                    if firstUserContent == nil {
                        firstUserContent = SessionDisplayText.preview(from: content)
                    }
                }
            case "assistant.message":
                if Self.nonEmptyString(data["content"]) != nil { messageCount += 1 }
            default:
                break
            }

            if bounded, projectCwd != nil, firstUserContent != nil, startedAt != nil {
                return false
            }
            return true
        }

        guard let projectCwd else {
            throw GitHubCopilotReaderError.missingProjectContext(candidate.sessionId)
        }
        let countUnknown = !result.reachedEndOfFile || result.skippedOversizedLines > 0
        let fallbackTitle = firstUserContent.flatMap { SessionDisplayText.title(from: $0) }
        return DiscoveredSession(
            tool: toolId,
            toolSessionId: candidate.sessionId,
            sourcePath: sourcePath,
            projectCwd: projectCwd,
            startedAt: startedAt ?? candidate.modifiedAt,
            updatedAt: candidate.modifiedAt,
            messageCount: countUnknown ? -1 : messageCount,
            title: explicitTitle ?? fallbackTitle,
            preview: firstUserContent ?? explicitTitle ?? ""
        )
    }

    private func parseDetail(_ candidate: Candidate) throws -> SessionDetail {
        var cwd: String?
        var startedAt: Date?
        var messages: [SessionMessage] = []
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
            let clippedToolInput = toolInput.map { String($0.prefix(allowed)) }
            if let toolInput, clippedToolInput?.count != toolInput.count { truncatedContent = true }
            messages.append(SessionMessage(
                role: role,
                content: clipped,
                timestamp: timestamp,
                toolName: toolName,
                toolInput: clippedToolInput
            ))
            totalCharacters += clipped.count
            if messages.count >= Self.detailMessageLimit
                || totalCharacters >= Self.detailCharacterLimit {
                hitBudget = true
            }
        }

        let result = try JSONLStreamReader.forEachLine(
            at: candidate.file,
            byteLimit: Self.detailScanBytes,
            maximumLineBytes: Self.maximumLineBytes
        ) { line in
            guard let event = Self.event(from: line), event["agentId"] == nil,
                  let type = event["type"] as? String,
                  let data = event["data"] as? [String: Any] else { return !hitBudget }
            let timestamp = Self.date(event["timestamp"]) ?? candidate.modifiedAt
            if startedAt == nil || timestamp < startedAt! { startedAt = timestamp }

            switch type {
            case "session.context_changed":
                cwd = Self.projectPath(from: data) ?? cwd
            case "user.message":
                if let content = Self.nonEmptyString(data["content"]),
                   let display = SessionDisplayText.cleanedUserText(content) {
                    appendMessage(role: .user, content: display, timestamp: timestamp)
                }
            case "assistant.message":
                if let content = Self.nonEmptyString(data["content"]) {
                    appendMessage(role: .assistant, content: content, timestamp: timestamp)
                }
                if let requests = data["toolRequests"] as? [[String: Any]] {
                    for request in requests {
                        guard let name = Self.nonEmptyString(request["name"]) else { continue }
                        let input = Self.jsonString(request["arguments"]) ?? ""
                        appendMessage(
                            role: .tool,
                            content: input,
                            timestamp: timestamp,
                            toolName: name,
                            toolInput: input
                        )
                        if hitBudget { break }
                    }
                }
            default:
                break
            }
            return !hitBudget
        }

        guard let cwd else {
            throw GitHubCopilotReaderError.missingProjectContext(candidate.sessionId)
        }
        return SessionDetail(
            tool: toolId,
            toolSessionId: candidate.sessionId,
            cwd: cwd,
            startedAt: startedAt ?? candidate.modifiedAt,
            messages: messages,
            isTruncated: hitBudget || truncatedContent || !result.reachedEndOfFile
                || result.skippedOversizedLines > 0
        )
    }

    private static func event(from line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
    }

    private static func projectPath(from data: [String: Any]) -> String? {
        if let gitRoot = absolutePath(data["gitRoot"]) { return gitRoot }
        return absolutePath(data["cwd"])
    }

    private static func absolutePath(_ value: Any?) -> String? {
        guard let value = nonEmptyString(value), value.hasPrefix("/") else { return nil }
        return (value as NSString).standardizingPath
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

public enum GitHubCopilotReaderError: LocalizedError, Sendable, Equatable {
    case sessionNotFound(String)
    case missingProjectContext(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "未找到 GitHub Copilot CLI 会话：\(id)"
        case .missingProjectContext(let id):
            return "GitHub Copilot CLI 会话缺少可验证的项目路径：\(id)"
        }
    }
}
