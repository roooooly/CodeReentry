import Foundation
import SQLite3

/// Bounded, read-only discovery and conversation loading for OpenCode v1.18.19
/// SQLite session storage.
///
/// OpenCode stores its default database at
/// `~/.local/share/opencode/opencode.db`. DevHub opens candidate databases with
/// `SQLITE_OPEN_READONLY`, validates the named schema before querying it, and
/// keeps discovery metadata-only. Message and part JSON is read only when the
/// user opens a conversation, with hard message, part, JSON, and text budgets.
/// Reasoning parts are never exposed. Discovery only runs through the app's
/// explicit refresh action.
public struct OpenCodeReader: SessionReader {
    public let toolId = "opencode"

    private static let databaseLimit = 8
    private static let sessionLimitPerDatabase = 1_000
    private static let detailMessageLimit = 500
    private static let detailPartLimit = 2_000
    private static let detailCharacterLimit = 2_000_000
    private static let perPartCharacterLimit = 50_000
    private static let jsonByteLimit = 2 * 1_024 * 1_024
    private let databaseURLs: [URL]
    private let maxDatabases: Int
    private let maxSessionsPerDatabase: Int
    private let maxDetailMessages: Int
    private let maxDetailParts: Int
    private let maxDetailCharacters: Int
    private let maxDetailJSONBytes: Int

    public init(
        databaseURLs: [URL]? = nil,
        homeURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxDatabases: Int = 8,
        maxSessionsPerDatabase: Int = 1_000,
        maxDetailMessages: Int = 500,
        maxDetailParts: Int = 2_000,
        maxDetailCharacters: Int = 2_000_000,
        maxDetailJSONBytes: Int = 2 * 1_024 * 1_024
    ) {
        let home = homeURL ?? FileManager.default.homeDirectoryForCurrentUser
        let boundedDatabaseCount = min(max(1, maxDatabases), Self.databaseLimit)
        self.databaseURLs = databaseURLs ?? Self.standardDatabaseURLs(
            homeURL: home,
            environment: environment,
            maxDatabases: boundedDatabaseCount
        )
        self.maxDatabases = boundedDatabaseCount
        self.maxSessionsPerDatabase = min(
            max(1, maxSessionsPerDatabase),
            Self.sessionLimitPerDatabase
        )
        self.maxDetailMessages = min(max(1, maxDetailMessages), Self.detailMessageLimit)
        self.maxDetailParts = min(max(1, maxDetailParts), Self.detailPartLimit)
        self.maxDetailCharacters = min(
            max(1, maxDetailCharacters),
            Self.detailCharacterLimit
        )
        self.maxDetailJSONBytes = min(max(1, maxDetailJSONBytes), Self.jsonByteLimit)
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

        var discovered: [DiscoveredSession] = []
        for databaseURL in databaseURLs.prefix(maxDatabases) {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { continue }

            let sourcePath = JSONLStreamReader.canonicalPath(databaseURL.path)
            let sourceDate = Self.latestSQLiteModificationDate(databaseURL)
            if let indexedAt = normalizedKnownFiles[sourcePath], indexedAt >= sourceDate {
                continue
            }
            discovered.append(contentsOf: try query(databaseURL: databaseURL, sourcePath: sourcePath))
        }
        return discovered
    }

    public func load(_ id: String) async throws -> SessionDetail {
        for databaseURL in databaseURLs.prefix(maxDatabases) {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: databaseURL.path) else { continue }
            if let detail = try queryDetail(databaseURL: databaseURL, sessionId: id) {
                return detail
            }
        }
        throw OpenCodeReaderError.sessionNotFound(id)
    }

    static func standardDatabaseURLs(
        homeURL: URL,
        environment: [String: String],
        maxDatabases: Int
    ) -> [URL] {
        let fm = FileManager.default
        var candidates: [URL] = []

        if let configured = environment["OPENCODE_DB"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            let expanded = (configured as NSString).expandingTildeInPath
            candidates.append(URL(fileURLWithPath: expanded))
        }

        let directory = homeURL
            .appendingPathComponent(".local/share/opencode", isDirectory: true)
        let defaultDatabase = directory.appendingPathComponent("opencode.db")
        candidates.append(defaultDatabase)

        let channelDatabases = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        candidates.append(contentsOf: channelDatabases
            .filter {
                $0.pathExtension == "db"
                    && $0.lastPathComponent.hasPrefix("opencode-")
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent })

        var seen: Set<String> = []
        return candidates.compactMap { url in
            let path = JSONLStreamReader.canonicalPath(url.path)
            guard seen.insert(path).inserted else { return nil }
            return URL(fileURLWithPath: path)
        }.prefix(max(1, maxDatabases)).map { $0 }
    }

    private func query(databaseURL: URL, sourcePath: String) throws -> [DiscoveredSession] {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw OpenCodeReaderError.databaseOpenFailed(databaseURL.path, message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        try validateSchema(database: database, path: databaseURL.path)

        let sql = """
        SELECT id, directory, title, time_created, time_updated
        FROM session
        WHERE time_archived IS NULL
        ORDER BY time_updated DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OpenCodeReaderError.queryFailed(
                databaseURL.path,
                String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(maxSessionsPerDatabase))

        var sessions: [DiscoveredSession] = []
        var rowNumber = 0
        while true {
            if rowNumber.isMultiple(of: 32) { try Task.checkCancellation() }
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw OpenCodeReaderError.queryFailed(
                    databaseURL.path,
                    String(cString: sqlite3_errmsg(database))
                )
            }
            rowNumber += 1

            guard let id = Self.nonEmptyText(statement, column: 0),
                  let directory = Self.nonEmptyText(statement, column: 1),
                  let title = Self.nonEmptyText(statement, column: 2),
                  sqlite3_column_type(statement, 3) == SQLITE_INTEGER,
                  sqlite3_column_type(statement, 4) == SQLITE_INTEGER else {
                throw OpenCodeReaderError.malformedRecord(databaseURL.path, rowNumber)
            }

            let createdAt = Self.date(milliseconds: sqlite3_column_int64(statement, 3))
            let updatedAt = Self.date(milliseconds: sqlite3_column_int64(statement, 4))
            sessions.append(DiscoveredSession(
                tool: toolId,
                toolSessionId: id,
                sourcePath: sourcePath,
                projectCwd: directory,
                startedAt: createdAt,
                updatedAt: updatedAt,
                // Discovery deliberately does not scan OpenCode's message rows.
                // A clean title is enough for the UI to offer bounded on-demand loading.
                messageCount: -1,
                title: title,
                preview: title
            ))
        }
        return sessions
    }

    private struct DetailMessageRow {
        let id: String
        let role: MessageRole
    }

    private struct DetailPartRow {
        let messageId: String
        let timestamp: Date
        let data: [String: Any]
    }

    private func queryDetail(databaseURL: URL, sessionId: String) throws -> SessionDetail? {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw OpenCodeReaderError.databaseOpenFailed(databaseURL.path, message)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        try validateSchema(database: database, path: databaseURL.path)
        guard let session = try sessionMetadata(
            database: database,
            path: databaseURL.path,
            sessionId: sessionId
        ) else { return nil }

        try validateSchema(
            database: database,
            path: databaseURL.path,
            table: "message",
            required: ["id", "session_id", "time_created", "data"]
        )
        try validateSchema(
            database: database,
            path: databaseURL.path,
            table: "part",
            required: ["id", "message_id", "session_id", "time_created", "data"]
        )

        var isTruncated = false
        let messageRows = try detailMessages(
            database: database,
            path: databaseURL.path,
            sessionId: sessionId,
            isTruncated: &isTruncated
        )
        let parts = try detailParts(
            database: database,
            path: databaseURL.path,
            sessionId: sessionId,
            messageRows: messageRows,
            isTruncated: &isTruncated
        )

        var remainingCharacters = maxDetailCharacters
        var messages: [SessionMessage] = []
        let roles = Dictionary(uniqueKeysWithValues: messageRows.map { ($0.id, $0) })
        for part in parts {
            guard let message = roles[part.messageId], remainingCharacters > 0 else {
                if remainingCharacters <= 0 { isTruncated = true }
                continue
            }
            guard let type = Self.nonEmptyString(part.data["type"])?.lowercased() else {
                isTruncated = true
                continue
            }
            switch type {
            case "text":
                if part.data["ignored"] as? Bool == true { continue }
                guard let raw = Self.nonEmptyString(part.data["text"]),
                      let content = Self.boundedText(
                        raw,
                        remainingCharacters: &remainingCharacters,
                        isTruncated: &isTruncated
                      ) else { continue }
                let visible = message.role == .user
                    ? SessionDisplayText.cleanedUserText(content)
                    : content
                guard let visible else { continue }
                messages.append(SessionMessage(
                    role: message.role,
                    content: visible,
                    timestamp: part.timestamp
                ))
            case "tool":
                guard let rawTool = Self.nonEmptyString(part.data["tool"]),
                      let tool = Self.boundedText(
                        rawTool,
                        remainingCharacters: &remainingCharacters,
                        isTruncated: &isTruncated
                      ) else {
                    isTruncated = true
                    continue
                }
                let state = part.data["state"] as? [String: Any]
                let rawTitle = Self.nonEmptyString(state?["title"])
                    ?? String(localized: "工具调用")
                guard let title = Self.boundedText(
                    rawTitle,
                    remainingCharacters: &remainingCharacters,
                    isTruncated: &isTruncated
                ) else { continue }
                let input = Self.prettyJSON(state?["input"]) ?? "{}"
                guard let boundedInput = Self.boundedText(
                    input,
                    remainingCharacters: &remainingCharacters,
                    isTruncated: &isTruncated
                ) else { continue }
                messages.append(SessionMessage(
                    role: .tool,
                    content: title,
                    timestamp: part.timestamp,
                    toolName: tool,
                    toolInput: boundedInput
                ))
            case "reasoning":
                // OpenCode persists model reasoning separately. It is not user-facing
                // conversation content and must not be surfaced by CodeReentry.
                continue
            default:
                // Attachments, snapshots, retry markers, and execution bookkeeping
                // stay in the source database and do not become conversation text.
                continue
            }
        }

        return SessionDetail(
            tool: toolId,
            toolSessionId: sessionId,
            cwd: session.cwd,
            startedAt: session.startedAt,
            // Parts are budgeted newest-first so an oversized conversation keeps
            // the context closest to resume. Restore chronological display order.
            messages: Array(messages.reversed()),
            isTruncated: isTruncated
        )
    }

    private func sessionMetadata(
        database: OpaquePointer,
        path: String,
        sessionId: String
    ) throws -> (cwd: String, startedAt: Date)? {
        let sql = "SELECT directory, time_created FROM session WHERE id = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OpenCodeReaderError.queryFailed(path, String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(sessionId, to: statement, index: 1, database: database, path: path)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW,
              let cwd = Self.nonEmptyText(statement, column: 0),
              sqlite3_column_type(statement, 1) == SQLITE_INTEGER else {
            throw OpenCodeReaderError.malformedConversation(path, "session")
        }
        return (cwd, Self.date(milliseconds: sqlite3_column_int64(statement, 1)))
    }

    private func detailMessages(
        database: OpaquePointer,
        path: String,
        sessionId: String,
        isTruncated: inout Bool
    ) throws -> [DetailMessageRow] {
        let sql = """
        SELECT id, time_created,
               CASE WHEN length(CAST(data AS BLOB)) <= ?3 THEN data END
        FROM message
        WHERE session_id = ?1
        ORDER BY time_created DESC, id DESC
        LIMIT ?2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OpenCodeReaderError.queryFailed(path, String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(sessionId, to: statement, index: 1, database: database, path: path)
        sqlite3_bind_int(statement, 2, Int32(maxDetailMessages + 1))
        sqlite3_bind_int64(statement, 3, sqlite3_int64(maxDetailJSONBytes))

        var rows: [DetailMessageRow] = []
        var rowCount = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw OpenCodeReaderError.queryFailed(path, String(cString: sqlite3_errmsg(database)))
            }
            rowCount += 1
            if rowCount.isMultiple(of: 32) { try Task.checkCancellation() }
            guard let id = Self.nonEmptyText(statement, column: 0),
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  let raw = Self.boundedColumnText(
                    statement,
                    column: 2,
                    byteLimit: maxDetailJSONBytes
                  ),
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let role = Self.conversationRole(object["role"]) else {
                isTruncated = true
                continue
            }
            rows.append(DetailMessageRow(
                id: id,
                role: role
            ))
        }
        if rowCount > maxDetailMessages { isTruncated = true }
        if rows.count > maxDetailMessages {
            rows = Array(rows.prefix(maxDetailMessages))
        }
        return rows.reversed()
    }

    private func detailParts(
        database: OpaquePointer,
        path: String,
        sessionId: String,
        messageRows: [DetailMessageRow],
        isTruncated: inout Bool
    ) throws -> [DetailPartRow] {
        guard !messageRows.isEmpty else { return [] }
        let sql = """
        SELECT part.message_id, part.time_created,
               CASE WHEN length(CAST(part.data AS BLOB)) <= ?4 THEN part.data END
        FROM part
        INNER JOIN (
            SELECT id
            FROM message
            WHERE session_id = ?1
            ORDER BY time_created DESC, id DESC
            LIMIT ?2
        ) AS selected ON selected.id = part.message_id
        WHERE part.session_id = ?1
        ORDER BY part.time_created DESC, part.id DESC
        LIMIT ?3
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OpenCodeReaderError.queryFailed(path, String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(sessionId, to: statement, index: 1, database: database, path: path)
        sqlite3_bind_int(statement, 2, Int32(maxDetailMessages))
        sqlite3_bind_int(statement, 3, Int32(maxDetailParts + 1))
        sqlite3_bind_int64(statement, 4, sqlite3_int64(maxDetailJSONBytes))

        let includedMessageIds = Set(messageRows.map(\.id))
        var rows: [DetailPartRow] = []
        var rowCount = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw OpenCodeReaderError.queryFailed(path, String(cString: sqlite3_errmsg(database)))
            }
            rowCount += 1
            if rowCount.isMultiple(of: 32) { try Task.checkCancellation() }
            guard let messageId = Self.nonEmptyText(statement, column: 0),
                  includedMessageIds.contains(messageId),
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  let raw = Self.boundedColumnText(
                    statement,
                    column: 2,
                    byteLimit: maxDetailJSONBytes
                  ),
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                isTruncated = true
                continue
            }
            rows.append(DetailPartRow(
                messageId: messageId,
                timestamp: Self.date(milliseconds: sqlite3_column_int64(statement, 1)),
                data: object
            ))
        }
        if rowCount > maxDetailParts { isTruncated = true }
        if rows.count > maxDetailParts {
            rows = Array(rows.prefix(maxDetailParts))
        }
        // Keep newest-first here so the total character budget retains resume-near
        // context. queryDetail reverses the rendered result for display.
        return rows
    }

    private func validateSchema(database: OpaquePointer, path: String) throws {
        try validateSchema(
            database: database,
            path: path,
            table: "session",
            required: ["id", "directory", "title", "time_created", "time_updated", "time_archived"]
        )
    }

    private func validateSchema(
        database: OpaquePointer,
        path: String,
        table: String,
        required: Set<String>
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OpenCodeReaderError.queryFailed(path, String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = Self.nonEmptyText(statement, column: 1) { columns.insert(name) }
        }
        let missing = required.subtracting(columns).sorted().map { "\(table).\($0)" }
        guard missing.isEmpty else {
            throw OpenCodeReaderError.unsupportedSchema(path, missing)
        }
    }

    private static func bind(
        _ value: String,
        to statement: OpaquePointer,
        index: Int32,
        database: OpaquePointer,
        path: String
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, transient)
        }
        guard result == SQLITE_OK else {
            throw OpenCodeReaderError.queryFailed(path, String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func boundedColumnText(
        _ statement: OpaquePointer,
        column: Int32,
        byteLimit: Int
    ) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= byteLimit, let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(decoding: UnsafeBufferPointer(start: raw, count: count), as: UTF8.self)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func conversationRole(_ value: Any?) -> MessageRole? {
        switch nonEmptyString(value)?.lowercased() {
        case "user": .user
        case "assistant": .assistant
        default: nil
        }
    }

    private static func boundedText(
        _ value: String,
        remainingCharacters: inout Int,
        isTruncated: inout Bool
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, remainingCharacters > 0 else { return nil }
        let allowed = min(Self.perPartCharacterLimit, remainingCharacters)
        if trimmed.count > allowed {
            isTruncated = true
            let clipped = String(trimmed.prefix(allowed))
            remainingCharacters -= clipped.count
            return clipped
        }
        remainingCharacters -= trimmed.count
        return trimmed
    }

    private static func prettyJSON(_ value: Any?) -> String? {
        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.prettyPrinted, .sortedKeys]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func nonEmptyText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func date(milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }

    private static func latestSQLiteModificationDate(_ databaseURL: URL) -> Date {
        let fm = FileManager.default
        let paths = [databaseURL.path, databaseURL.path + "-wal"]
        return paths.compactMap {
            (try? fm.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
        }.max() ?? .distantPast
    }
}

public enum OpenCodeReaderError: LocalizedError, Sendable, Equatable {
    case databaseOpenFailed(String, String)
    case unsupportedSchema(String, [String])
    case malformedRecord(String, Int)
    case malformedConversation(String, String)
    case queryFailed(String, String)
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let path, let detail):
            return "OpenCode 数据库无法以只读方式打开：\(path)（\(detail)）"
        case .unsupportedSchema(let path, let columns):
            return "OpenCode 数据库格式不受支持：\(path)（缺少字段：\(columns.joined(separator: ", "))）"
        case .malformedRecord(let path, let row):
            return "OpenCode 数据库包含无效会话记录：\(path)（第 \(row) 行）"
        case .malformedConversation(let path, let table):
            return "OpenCode 数据库包含无效对话记录：\(path)（\(table)）"
        case .queryFailed(let path, let detail):
            return "读取 OpenCode 会话数据失败：\(path)（\(detail)）"
        case .sessionNotFound(let id):
            return "未找到 OpenCode 会话：\(id)"
        }
    }
}
