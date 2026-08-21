import Foundation

/// Bounded, read-only access to Aider's project-level Markdown history.
///
/// Aider v0.86.2 writes the default history to `.aider.chat.history.md` in
/// the Git root. It marks user input with `#### `, ordinary Markdown is the
/// assistant response, `> ` is tool/UI output, and `# aider chat started at`
/// records each launch. Aider's own restore parser excludes the tool/UI rows;
/// this reader mirrors that boundary and never writes to the source file.
///
/// Aider has one continuing default history per project, not durable session
/// IDs. CodeReentry therefore exposes at most one Aider record for each exact
/// registered project root and resumes it with `--restore-chat-history`.
public struct AiderReader: SessionReader {
    public let toolId = "aider"
    public let projectRoots: [URL]

    private static let projectLimit = 1_000
    private static let metadataTailByteLimit: UInt64 = 4 * 1_024 * 1_024
    private static let detailTailByteLimit: UInt64 = 64 * 1_024 * 1_024
    private static let lineByteLimit = 1 * 1_024 * 1_024
    private static let detailMessageLimit = 500
    private static let detailCharacterLimit = 2_000_000
    private static let perMessageCharacterLimit = 50_000

    private let maxProjectRoots: Int
    private let metadataTailBytes: UInt64
    private let detailTailBytes: UInt64
    private let maxLineBytes: Int
    private let maxDetailMessages: Int
    private let maxDetailCharacters: Int

    public init(
        projectRoots: [URL],
        maxProjectRoots: Int = 1_000,
        metadataTailBytes: UInt64 = 4 * 1_024 * 1_024,
        detailTailBytes: UInt64 = 64 * 1_024 * 1_024,
        maxLineBytes: Int = 1 * 1_024 * 1_024,
        maxDetailMessages: Int = 500,
        maxDetailCharacters: Int = 2_000_000
    ) {
        var seen: Set<String> = []
        self.projectRoots = projectRoots.compactMap { root in
            let normalizedPath = (root.path as NSString).standardizingPath
            let normalized = URL(fileURLWithPath: normalizedPath, isDirectory: true)
            return seen.insert(normalized.path).inserted ? normalized : nil
        }
        self.maxProjectRoots = min(max(1, maxProjectRoots), Self.projectLimit)
        self.metadataTailBytes = min(
            max(1, metadataTailBytes), Self.metadataTailByteLimit
        )
        self.detailTailBytes = min(max(1, detailTailBytes), Self.detailTailByteLimit)
        self.maxLineBytes = min(max(1, maxLineBytes), Self.lineByteLimit)
        self.maxDetailMessages = min(
            max(1, maxDetailMessages), Self.detailMessageLimit
        )
        self.maxDetailCharacters = min(
            max(1, maxDetailCharacters), Self.detailCharacterLimit
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
        for candidate in try candidates() {
            try Task.checkCancellation()
            let sourcePath = JSONLStreamReader.canonicalPath(candidate.file.path)
            if let indexedAt = normalizedKnownFiles[sourcePath],
               indexedAt >= candidate.modifiedAt {
                continue
            }
            if let session = try parseMetadata(candidate, sourcePath: sourcePath) {
                sessions.append(session)
            }
        }
        return sessions
    }

    public func load(_ id: String) async throws -> SessionDetail {
        guard let candidate = try candidates().first(where: { $0.sessionID == id }) else {
            throw AiderReaderError.sessionNotFound(id)
        }
        return try parseDetail(candidate)
    }

    private struct Candidate: Sendable {
        let sessionID: String
        let projectRoot: URL
        let file: URL
        let modifiedAt: Date
    }

    private func candidates() throws -> [Candidate] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        var result: [Candidate] = []
        for root in projectRoots.prefix(maxProjectRoots) {
            try Task.checkCancellation()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: root.path,
                isDirectory: &isDirectory
            ), isDirectory.boolValue else { continue }

            let file = root.appendingPathComponent(".aider.chat.history.md", isDirectory: false)
            let values = try? file.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true else { continue }
            let modifiedAt = values?.contentModificationDate ?? .distantPast
            result.append(Candidate(
                sessionID: root.path,
                projectRoot: root,
                file: file,
                modifiedAt: modifiedAt
            ))
        }
        return result.sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.sessionID < $1.sessionID
        }
    }

    private func parseMetadata(
        _ candidate: Candidate,
        sourcePath: String
    ) throws -> DiscoveredSession? {
        let tailOffset = JSONLStreamReader.tailOffset(
            for: candidate.file,
            maximumBytes: metadataTailBytes
        )
        var parser = MarkdownParser(
            fallbackTimestamp: candidate.modifiedAt,
            maxMessages: 20,
            maxCharacters: 200_000
        )
        let result = try read(
            candidate.file,
            startingAtOffset: tailOffset,
            byteLimit: metadataTailBytes,
            parser: &parser
        )
        parser.finish()

        guard let preview = parser.lastUserContent.flatMap({
            SessionDisplayText.preview(from: $0)
        }) else { return nil }
        let countUnknown = tailOffset > 0
            || !result.reachedEndOfFile
            || result.skippedOversizedLines > 0
        return DiscoveredSession(
            tool: toolId,
            toolSessionId: candidate.sessionID,
            sourcePath: sourcePath,
            projectCwd: candidate.projectRoot.path,
            startedAt: parser.latestHeaderDate ?? candidate.modifiedAt,
            updatedAt: candidate.modifiedAt,
            messageCount: countUnknown ? -1 : parser.totalMessageCount,
            title: SessionDisplayText.title(from: preview),
            preview: preview
        )
    }

    private func parseDetail(_ candidate: Candidate) throws -> SessionDetail {
        let tailOffset = JSONLStreamReader.tailOffset(
            for: candidate.file,
            maximumBytes: detailTailBytes
        )
        var parser = MarkdownParser(
            fallbackTimestamp: candidate.modifiedAt,
            maxMessages: maxDetailMessages,
            maxCharacters: maxDetailCharacters
        )
        let result = try read(
            candidate.file,
            startingAtOffset: tailOffset,
            byteLimit: detailTailBytes,
            parser: &parser
        )
        parser.finish()
        guard !parser.messages.isEmpty else {
            throw AiderReaderError.noConversation(candidate.sessionID)
        }
        return SessionDetail(
            tool: toolId,
            toolSessionId: candidate.sessionID,
            cwd: candidate.projectRoot.path,
            startedAt: parser.latestHeaderDate ?? candidate.modifiedAt,
            messages: parser.messages,
            isTruncated: tailOffset > 0
                || !result.reachedEndOfFile
                || result.skippedOversizedLines > 0
                || parser.wasTruncated
        )
    }

    private func read(
        _ file: URL,
        startingAtOffset: UInt64,
        byteLimit: UInt64,
        parser: inout MarkdownParser
    ) throws -> JSONLStreamReader.ReadResult {
        try JSONLStreamReader.forEachLine(
            at: file,
            startingAtOffset: startingAtOffset,
            byteLimit: byteLimit,
            maximumLineBytes: maxLineBytes,
            includeEmptyLines: true
        ) { data in
            parser.consume(String(decoding: data, as: UTF8.self))
            return true
        }
    }

    private struct MarkdownParser {
        private let maxMessages: Int
        private let maxCharacters: Int
        private let perMessageLimit: Int

        private(set) var messages: [SessionMessage] = []
        private(set) var totalMessageCount = 0
        private(set) var lastUserContent: String?
        private(set) var latestHeaderDate: Date?
        private(set) var wasTruncated = false

        private var retainedCharacters = 0
        private var currentTimestamp: Date
        private var userText = ""
        private var userTimestamp: Date?
        private var assistantText = ""
        private var assistantTimestamp: Date?

        init(fallbackTimestamp: Date, maxMessages: Int, maxCharacters: Int) {
            self.maxMessages = max(1, maxMessages)
            self.maxCharacters = max(1, maxCharacters)
            self.perMessageLimit = min(
                AiderReader.perMessageCharacterLimit,
                max(1, maxCharacters)
            )
            self.currentTimestamp = fallbackTimestamp
        }

        mutating func consume(_ line: String) {
            if let headerDate = Self.headerDate(line) {
                currentTimestamp = headerDate
                latestHeaderDate = headerDate
                return
            }
            // Aider's own restore parser skips level-one headings.
            if line.hasPrefix("# ") { return }
            // Tool prompts, status, token reports and command output are not
            // part of the restored user/assistant conversation.
            if line.hasPrefix("> ") {
                flushAssistant()
                flushUser()
                return
            }
            if line.hasPrefix("#### ") {
                flushAssistant()
                if userTimestamp == nil { userTimestamp = currentTimestamp }
                let result = Self.appending(
                    line: String(line.dropFirst(5)),
                    to: userText,
                    limit: perMessageLimit
                )
                userText = result.text
                if result.truncated { wasTruncated = true }
                return
            }

            flushUser()
            if assistantTimestamp == nil { assistantTimestamp = currentTimestamp }
            let result = Self.appending(
                line: line,
                to: assistantText,
                limit: perMessageLimit
            )
            assistantText = result.text
            if result.truncated { wasTruncated = true }
        }

        mutating func finish() {
            flushAssistant()
            flushUser()
        }

        private static func appending(
            line: String,
            to text: String,
            limit: Int
        ) -> (text: String, truncated: Bool) {
            let separator = text.isEmpty ? "" : "\n"
            let available = limit - text.count
            guard available > 0 else { return (text, true) }
            let addition = separator + line
            let clipped = String(addition.prefix(available))
            return (text + clipped, clipped.count < addition.count)
        }

        private mutating func flushUser() {
            let content = userText.trimmingCharacters(in: .whitespacesAndNewlines)
            userText = ""
            let timestamp = userTimestamp ?? currentTimestamp
            userTimestamp = nil
            guard !content.isEmpty else { return }
            lastUserContent = content
            appendMessage(role: .user, content: content, timestamp: timestamp)
        }

        private mutating func flushAssistant() {
            let content = assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
            assistantText = ""
            let timestamp = assistantTimestamp ?? currentTimestamp
            assistantTimestamp = nil
            guard !content.isEmpty else { return }
            appendMessage(role: .assistant, content: content, timestamp: timestamp)
        }

        private mutating func appendMessage(
            role: MessageRole,
            content: String,
            timestamp: Date
        ) {
            totalMessageCount += 1
            messages.append(SessionMessage(
                role: role,
                content: content,
                timestamp: timestamp
            ))
            retainedCharacters += content.count
            while messages.count > maxMessages || retainedCharacters > maxCharacters {
                guard !messages.isEmpty else { break }
                retainedCharacters -= messages.removeFirst().content.count
                wasTruncated = true
            }
        }

        private static func headerDate(_ line: String) -> Date? {
            let prefix = "# aider chat started at "
            guard line.hasPrefix(prefix) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter.date(from: String(line.dropFirst(prefix.count)))
        }
    }
}

public enum AiderReaderError: LocalizedError, Sendable, Equatable {
    case sessionNotFound(String)
    case noConversation(String)

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound(let id):
            return "未找到 Aider 项目历史：\(id)"
        case .noConversation(let id):
            return "Aider 项目历史不包含可显示的对话：\(id)"
        }
    }
}
