import Foundation
import SQLite3

/// Bounded, read-only access to Goose v1.46.0 user sessions.
///
/// Goose stores CLI and Desktop sessions in the same SQLite database. On macOS
/// the default is `~/Library/Application Support/Block/goose/sessions/sessions.db`;
/// an absolute `GOOSE_PATH_ROOT` moves it to `<root>/data/sessions/sessions.db`.
/// Discovery reads session metadata only. Conversation JSON is decoded only when
/// the user opens one session, and only user-visible text blocks are surfaced.
public struct GooseReader: SessionReader {
    public let toolId = "goose"

    private static let sessionHardLimit = 1_000
    private static let messageHardLimit = 500
    private static let characterHardLimit = 2_000_000
    private static let perMessageCharacterLimit = 50_000
    private static let jsonByteHardLimit = 2 * 1_024 * 1_024
    private static let identifierByteLimit = 4_096
    private static let pathByteLimit = 32_768
    private static let titleCharacterLimit = 500

    private let databaseURL: URL
    private let maxSessions: Int
    private let maxMessages: Int
    private let maxCharacters: Int
    private let maxJSONBytes: Int

    public init(
        databaseURL: URL? = nil,
        homeURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxSessions: Int = 1_000,
        maxMessages: Int = 500,
        maxCharacters: Int = 2_000_000,
        maxJSONBytes: Int = 2 * 1_024 * 1_024
    ) {
        let home = homeURL ?? FileManager.default.homeDirectoryForCurrentUser
        self.databaseURL = databaseURL ?? Self.standardDatabaseURL(
            homeURL: home,
            environment: environment
        )
        self.maxSessions = min(max(1, maxSessions), Self.sessionHardLimit)
        self.maxMessages = min(max(1, maxMessages), Self.messageHardLimit)
        self.maxCharacters = min(max(1, maxCharacters), Self.characterHardLimit)
        self.maxJSONBytes = min(max(1, maxJSONBytes), Self.jsonByteHardLimit)
    }

    public func discover() async throws -> [DiscoveredSession] {
        try await discover(knownFiles: [:])
    }

    public func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession] {
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return [] }

        let sourcePath = JSONLStreamReader.canonicalPath(databaseURL.path)
        let normalizedKnownFiles = Dictionary(grouping: knownFiles.keys) {
            JSONLStreamReader.canonicalPath($0)
        }.compactMapValues { paths in
            paths.compactMap { knownFiles[$0] }.max()
        }
        let sourceDate = Self.latestSQLiteModificationDate(databaseURL)
        if let indexedAt = normalizedKnownFiles[sourcePath], indexedAt >= sourceDate {
            return []
        }
        return try withReadOnlyDatabase { database in
            try validateSessionSchema(database: database)
            return try querySessions(database: database, sourcePath: sourcePath)
        }
    }

    public func load(_ id: String) async throws -> SessionDetail {
        try Task.checkCancellation()
        guard !id.isEmpty, id.utf8.count <= Self.identifierByteLimit,
              FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw GooseReaderError.sessionNotFound(id)
        }
        let detail = try withReadOnlyDatabase { database in
            try validateSessionSchema(database: database)
            try validateMessageSchema(database: database)
            return try queryDetail(database: database, sessionId: id)
        }
        guard let detail else { throw GooseReaderError.sessionNotFound(id) }
        return detail
    }

    static func standardDatabaseURL(
        homeURL: URL,
        environment: [String: String]
    ) -> URL {
        if let rawRoot = environment["GOOSE_PATH_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !rawRoot.isEmpty {
            let expanded = (rawRoot as NSString).expandingTildeInPath
            if (expanded as NSString).isAbsolutePath {
                return URL(fileURLWithPath: expanded, isDirectory: true)
                    .appendingPathComponent("data/sessions/sessions.db")
            }
        }
        return homeURL
            .appendingPathComponent("Library/Application Support/Block/goose", isDirectory: true)
            .appendingPathComponent("sessions/sessions.db")
    }

    private func withReadOnlyDatabase<T>(
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw GooseReaderError.databaseOpenFailed(databaseURL.path, detail)
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)
        return try body(database)
    }

    private func querySessions(
        database: OpaquePointer,
        sourcePath: String
    ) throws -> [DiscoveredSession] {
        let sql = """
        SELECT id, working_dir, name, description,
               unixepoch(created_at), unixepoch(updated_at)
        FROM sessions
        WHERE session_type = 'user'
        ORDER BY unixepoch(updated_at) DESC, id DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw queryError(database)
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(maxSessions))

        var sessions: [DiscoveredSession] = []
        var row = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw queryError(database) }
            row += 1
            if row.isMultiple(of: 32) { try Task.checkCancellation() }

            guard let id = Self.boundedNonEmptyText(
                statement, column: 0, byteLimit: Self.identifierByteLimit
            ), let cwd = Self.boundedNonEmptyText(
                statement, column: 1, byteLimit: Self.pathByteLimit
            ), sqlite3_column_type(statement, 4) == SQLITE_INTEGER,
               sqlite3_column_type(statement, 5) == SQLITE_INTEGER else {
                throw GooseReaderError.malformedRecord(databaseURL.path, row)
            }
            let name = Self.boundedOptionalText(statement, column: 2)
            let description = Self.boundedOptionalText(statement, column: 3)
            let title = name ?? description ?? id
            sessions.append(DiscoveredSession(
                tool: toolId,
                toolSessionId: id,
                sourcePath: sourcePath,
                projectCwd: cwd,
                startedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 4))),
                updatedAt: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 5))),
                messageCount: -1,
                title: title,
                preview: title
            ))
        }
        return sessions
    }

    private func queryDetail(
        database: OpaquePointer,
        sessionId: String
    ) throws -> SessionDetail? {
        guard let metadata = try sessionMetadata(database: database, sessionId: sessionId) else {
            return nil
        }
        let sql = """
        SELECT role, created_timestamp,
               CASE WHEN length(CAST(content_json AS BLOB)) <= ?3 THEN content_json END
        FROM messages
        WHERE session_id = ?1
          AND (metadata_json IS NULL OR (
            json_valid(metadata_json) = 1
            AND COALESCE(json_extract(metadata_json, '$.userVisible'), 1) != 0
          ))
        ORDER BY created_timestamp DESC, id DESC
        LIMIT ?2
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw queryError(database)
        }
        defer { sqlite3_finalize(statement) }
        try bind(sessionId, to: statement, index: 1, database: database)
        sqlite3_bind_int(statement, 2, Int32(maxMessages + 1))
        sqlite3_bind_int64(statement, 3, sqlite3_int64(maxJSONBytes))

        var messages: [SessionMessage] = []
        var remainingCharacters = maxCharacters
        var rowCount = 0
        var isTruncated = false
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw queryError(database) }
            rowCount += 1
            if rowCount.isMultiple(of: 32) { try Task.checkCancellation() }
            if rowCount > maxMessages {
                isTruncated = true
                continue
            }
            guard let role = Self.role(statement, column: 0),
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  let rawJSON = Self.boundedColumnText(
                    statement, column: 2, byteLimit: maxJSONBytes
                  ), let data = rawJSON.data(using: .utf8),
                  let blocks = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                isTruncated = true
                continue
            }

            var visibleBlocks: [String] = []
            for block in blocks {
                guard (block["type"] as? String)?.lowercased() == "text",
                      let text = block["text"] as? String,
                      let bounded = Self.boundedText(
                        text,
                        remainingCharacters: &remainingCharacters,
                        isTruncated: &isTruncated
                      ) else { continue }
                if let visible = role == .user
                    ? SessionDisplayText.cleanedUserText(bounded)
                    : bounded {
                    visibleBlocks.append(visible)
                }
            }
            if !visibleBlocks.isEmpty {
                messages.append(SessionMessage(
                    role: role,
                    content: visibleBlocks.joined(separator: "\n\n"),
                    timestamp: Self.messageDate(sqlite3_column_int64(statement, 1))
                ))
            }
            if remainingCharacters <= 0 { isTruncated = true }
        }

        return SessionDetail(
            tool: toolId,
            toolSessionId: sessionId,
            cwd: metadata.cwd,
            startedAt: metadata.startedAt,
            messages: Array(messages.reversed()),
            isTruncated: isTruncated
        )
    }

    private func sessionMetadata(
        database: OpaquePointer,
        sessionId: String
    ) throws -> (cwd: String, startedAt: Date)? {
        let sql = """
        SELECT working_dir, unixepoch(created_at)
        FROM sessions
        WHERE id = ? AND session_type = 'user'
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw queryError(database) }
        defer { sqlite3_finalize(statement) }
        try bind(sessionId, to: statement, index: 1, database: database)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW,
              let cwd = Self.boundedNonEmptyText(
                statement, column: 0, byteLimit: Self.pathByteLimit
              ), sqlite3_column_type(statement, 1) == SQLITE_INTEGER else {
            throw GooseReaderError.malformedConversation(databaseURL.path)
        }
        return (
            cwd,
            Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)))
        )
    }

    private func validateSessionSchema(database: OpaquePointer) throws {
        try validateSchema(
            database: database,
            table: "sessions",
            required: [
                "id", "name", "description", "session_type", "working_dir",
                "created_at", "updated_at"
            ]
        )
    }

    private func validateMessageSchema(database: OpaquePointer) throws {
        try validateSchema(
            database: database,
            table: "messages",
            required: [
                "id", "session_id", "role", "content_json", "created_timestamp",
                "metadata_json"
            ]
        )
    }

    private func validateSchema(
        database: OpaquePointer,
        table: String,
        required: Set<String>
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "PRAGMA table_info(\(table))", -1, &statement, nil
        ) == SQLITE_OK, let statement else { throw queryError(database) }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = Self.boundedNonEmptyText(statement, column: 1, byteLimit: 256) {
                columns.insert(name)
            }
        }
        let missing = required.subtracting(columns).sorted().map { "\(table).\($0)" }
        guard missing.isEmpty else {
            throw GooseReaderError.unsupportedSchema(databaseURL.path, missing)
        }
    }

    private func bind(
        _ value: String,
        to statement: OpaquePointer,
        index: Int32,
        database: OpaquePointer
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard result == SQLITE_OK else { throw queryError(database) }
    }

    private func queryError(_ database: OpaquePointer) -> GooseReaderError {
        .queryFailed(databaseURL.path, String(cString: sqlite3_errmsg(database)))
    }

    private static func role(_ statement: OpaquePointer, column: Int32) -> MessageRole? {
        switch boundedNonEmptyText(statement, column: column, byteLimit: 32)?.lowercased() {
        case "user": .user
        case "assistant": .assistant
        default: nil
        }
    }

    private static func boundedOptionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let raw = boundedColumnText(statement, column: column, byteLimit: 4_096) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(titleCharacterLimit))
    }

    private static func boundedNonEmptyText(
        _ statement: OpaquePointer,
        column: Int32,
        byteLimit: Int
    ) -> String? {
        guard let raw = boundedColumnText(statement, column: column, byteLimit: byteLimit) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boundedColumnText(
        _ statement: OpaquePointer,
        column: Int32,
        byteLimit: Int
    ) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count <= byteLimit, let raw = sqlite3_column_text(statement, column) else {
            return nil
        }
        return String(decoding: UnsafeBufferPointer(start: raw, count: count), as: UTF8.self)
    }

    private static func boundedText(
        _ value: String,
        remainingCharacters: inout Int,
        isTruncated: inout Bool
    ) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, remainingCharacters > 0 else { return nil }
        let allowed = min(perMessageCharacterLimit, remainingCharacters)
        if trimmed.count > allowed {
            isTruncated = true
            let clipped = String(trimmed.prefix(allowed))
            remainingCharacters -= clipped.count
            return clipped
        }
        remainingCharacters -= trimmed.count
        return trimmed
    }

    private static func messageDate(_ value: Int64) -> Date {
        let seconds = value > 1_000_000_000_000 ? Double(value) / 1_000 : Double(value)
        return Date(timeIntervalSince1970: seconds)
    }

    private static func latestSQLiteModificationDate(_ databaseURL: URL) -> Date {
        [databaseURL.path, databaseURL.path + "-wal"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate]) as? Date
        }.max() ?? .distantPast
    }
}

public enum GooseReaderError: LocalizedError, Sendable, Equatable {
    case databaseOpenFailed(String, String)
    case unsupportedSchema(String, [String])
    case malformedRecord(String, Int)
    case malformedConversation(String)
    case queryFailed(String, String)
    case sessionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let path, let detail):
            "Goose 数据库无法以只读方式打开：\(path)（\(detail)）"
        case .unsupportedSchema(let path, let columns):
            "Goose 数据库格式不受支持：\(path)（缺少字段：\(columns.joined(separator: ", "))）"
        case .malformedRecord(let path, let row):
            "Goose 数据库包含无效会话记录：\(path)（第 \(row) 行）"
        case .malformedConversation(let path):
            "Goose 数据库包含无效对话记录：\(path)"
        case .queryFailed(let path, let detail):
            "读取 Goose 会话数据失败：\(path)（\(detail)）"
        case .sessionNotFound(let id):
            "未找到 Goose 会话：\(id)"
        }
    }
}
