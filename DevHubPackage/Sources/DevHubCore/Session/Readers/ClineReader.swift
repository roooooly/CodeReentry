import Foundation
import SQLite3

/// Bounded, read-only access to Cline CLI v3.0.56 session history.
///
/// Current Cline stores root-session metadata in `~/.cline/data/db/sessions.db`
/// and one manifest plus message document under
/// `~/.cline/data/sessions/<session-id>/`. Discovery reads only metadata. The
/// selected message document is opened on demand with hard file, message, and
/// text budgets; only user/assistant text blocks are exposed.
public struct ClineReader: SessionReader {
    public let toolId = "cline"
    public let databaseURL: URL
    public let sessionsRoot: URL

    private static let sessionLimit = 1_000
    private static let manifestByteLimit = 2 * 1_024 * 1_024
    private static let detailByteLimit = 64 * 1_024 * 1_024
    private static let detailMessageLimit = 500
    private static let detailCharacterLimit = 2_000_000
    private static let perMessageCharacterLimit = 50_000

    private let maxSessions: Int
    private let maxDetailBytes: Int
    private let maxDetailMessages: Int
    private let maxDetailCharacters: Int

    public init(
        databaseURL: URL? = nil,
        sessionsRoot: URL? = nil,
        homeURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxSessions: Int = 1_000,
        maxDetailBytes: Int = 64 * 1_024 * 1_024,
        maxDetailMessages: Int = 500,
        maxDetailCharacters: Int = 2_000_000
    ) {
        let home = homeURL ?? FileManager.default.homeDirectoryForCurrentUser
        let clineDirectory = Self.configuredDirectory(
            environment["CLINE_DIR"], fallback: home.appendingPathComponent(".cline")
        )
        let dataDirectory = Self.configuredDirectory(
            environment["CLINE_DATA_DIR"],
            fallback: clineDirectory.appendingPathComponent("data", isDirectory: true)
        )
        let databaseDirectory = Self.configuredDirectory(
            environment["CLINE_DB_DATA_DIR"],
            fallback: dataDirectory.appendingPathComponent("db", isDirectory: true)
        )
        let sessionDirectory = Self.configuredDirectory(
            environment["CLINE_SESSION_DATA_DIR"],
            fallback: dataDirectory.appendingPathComponent("sessions", isDirectory: true)
        )
        self.databaseURL = databaseURL ?? databaseDirectory.appendingPathComponent("sessions.db")
        self.sessionsRoot = sessionsRoot ?? sessionDirectory
        self.maxSessions = min(max(1, maxSessions), Self.sessionLimit)
        self.maxDetailBytes = min(max(1, maxDetailBytes), Self.detailByteLimit)
        self.maxDetailMessages = min(max(1, maxDetailMessages), Self.detailMessageLimit)
        self.maxDetailCharacters = min(
            max(1, maxDetailCharacters), Self.detailCharacterLimit
        )
    }

    public func discover() async throws -> [DiscoveredSession] {
        try await discover(knownFiles: [:])
    }

    public func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession] {
        let known = Self.normalizedKnownFiles(knownFiles)
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            let sourcePath = JSONLStreamReader.canonicalPath(databaseURL.path)
            let modifiedAt = Self.latestSQLiteModificationDate(databaseURL)
            if let indexedAt = known[sourcePath], indexedAt >= modifiedAt { return [] }
            return try queryDatabase(sourcePath: sourcePath)
        }
        return try discoverManifests(knownFiles: known)
    }

    public func load(_ id: String) async throws -> SessionDetail {
        guard Self.isSafeSessionID(id) else { throw ClineReaderError.sessionNotFound(id) }
        if FileManager.default.fileExists(atPath: databaseURL.path),
           let record = try queryDatabaseRecord(sessionID: id) {
            return try loadMessages(record)
        }
        if let record = try manifestRecord(sessionID: id) {
            return try loadMessages(record)
        }
        throw ClineReaderError.sessionNotFound(id)
    }

    private struct Record {
        let id: String
        let cwd: String
        let startedAt: Date
        let updatedAt: Date
        let prompt: String?
        let title: String?
        let messagesPath: String?
        let sourcePath: String
    }

    private func queryDatabase(sourcePath: String) throws -> [DiscoveredSession] {
        try Self.requireSafeRegularFile(databaseURL, label: "database")
        let database = try Self.openDatabase(databaseURL)
        defer { sqlite3_close(database) }
        try Self.validateSchema(database, path: databaseURL.path)

        let sql = """
        SELECT session_id, started_at, updated_at, cwd, workspace_root,
               CASE WHEN length(CAST(prompt AS BLOB)) <= ?2 THEN prompt END,
               CASE WHEN length(CAST(metadata_json AS BLOB)) <= ?3 THEN metadata_json END,
               messages_path
        FROM sessions
        WHERE is_subagent = 0
          AND (parent_session_id IS NULL OR trim(parent_session_id) = '')
        ORDER BY started_at DESC, session_id DESC
        LIMIT ?1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ClineReaderError.queryFailed(
                databaseURL.path, String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(maxSessions))
        sqlite3_bind_int64(statement, 2, sqlite3_int64(Self.perMessageCharacterLimit * 4))
        sqlite3_bind_int64(statement, 3, sqlite3_int64(Self.manifestByteLimit))

        var result: [DiscoveredSession] = []
        var row = 0
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw ClineReaderError.queryFailed(
                    databaseURL.path, String(cString: sqlite3_errmsg(database))
                )
            }
            row += 1
            if row.isMultiple(of: 32) { try Task.checkCancellation() }
            let record = try Self.databaseRecord(
                statement, sourcePath: sourcePath, path: databaseURL.path, row: row
            )
            result.append(Self.discoveredSession(record))
        }
        return result
    }

    private func queryDatabaseRecord(sessionID: String) throws -> Record? {
        try Self.requireSafeRegularFile(databaseURL, label: "database")
        let database = try Self.openDatabase(databaseURL)
        defer { sqlite3_close(database) }
        try Self.validateSchema(database, path: databaseURL.path)
        let sql = """
        SELECT session_id, started_at, updated_at, cwd, workspace_root,
               CASE WHEN length(CAST(prompt AS BLOB)) <= ?2 THEN prompt END,
               CASE WHEN length(CAST(metadata_json AS BLOB)) <= ?3 THEN metadata_json END,
               messages_path
        FROM sessions
        WHERE session_id = ?1 AND is_subagent = 0
          AND (parent_session_id IS NULL OR trim(parent_session_id) = '')
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw ClineReaderError.queryFailed(
                databaseURL.path, String(cString: sqlite3_errmsg(database))
            )
        }
        defer { sqlite3_finalize(statement) }
        try Self.bind(sessionID, to: statement, index: 1, database: database)
        sqlite3_bind_int64(statement, 2, sqlite3_int64(Self.perMessageCharacterLimit * 4))
        sqlite3_bind_int64(statement, 3, sqlite3_int64(Self.manifestByteLimit))
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else {
            throw ClineReaderError.queryFailed(
                databaseURL.path, String(cString: sqlite3_errmsg(database))
            )
        }
        return try Self.databaseRecord(
            statement,
            sourcePath: JSONLStreamReader.canonicalPath(databaseURL.path),
            path: databaseURL.path,
            row: 1
        )
    }

    private static func databaseRecord(
        _ statement: OpaquePointer,
        sourcePath: String,
        path: String,
        row: Int
    ) throws -> Record {
        guard let id = nonEmptyText(statement, column: 0), isSafeSessionID(id),
              let startedRaw = nonEmptyText(statement, column: 1),
              let updatedRaw = nonEmptyText(statement, column: 2),
              let startedAt = isoDate(startedRaw), let updatedAt = isoDate(updatedRaw),
              let cwdRaw = nonEmptyText(statement, column: 3),
              let workspaceRaw = nonEmptyText(statement, column: 4),
              let cwd = absoluteProjectPath(workspaceRaw) ?? absoluteProjectPath(cwdRaw) else {
            throw ClineReaderError.malformedRecord(path, row)
        }
        let prompt = optionalText(statement, column: 5)
        let metadata = optionalText(statement, column: 6)
        let title = metadata.flatMap(metadataTitle)
        return Record(
            id: id, cwd: cwd, startedAt: startedAt, updatedAt: updatedAt,
            prompt: prompt, title: title,
            messagesPath: optionalText(statement, column: 7), sourcePath: sourcePath
        )
    }

    private func discoverManifests(
        knownFiles: [String: Date]
    ) throws -> [DiscoveredSession] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsRoot.path) else { return [] }
        let directories = (try? fm.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var result: [DiscoveredSession] = []
        for directory in directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
            .prefix(maxSessions) {
            try Task.checkCancellation()
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let id = directory.lastPathComponent
            guard values?.isDirectory == true, values?.isSymbolicLink != true,
                  Self.isSafeSessionID(id) else { continue }
            let manifest = directory.appendingPathComponent("\(id).json")
            guard let modifiedAt = try? manifest.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate else { continue }
            let sourcePath = JSONLStreamReader.canonicalPath(manifest.path)
            if let indexedAt = knownFiles[sourcePath], indexedAt >= modifiedAt { continue }
            if let record = try manifestRecord(sessionID: id) {
                result.append(Self.discoveredSession(record))
            }
        }
        return result.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.toolSessionId > $1.toolSessionId
        }
    }

    private func manifestRecord(sessionID: String) throws -> Record? {
        guard Self.isSafeSessionID(sessionID) else { return nil }
        let manifestURL = sessionsRoot
            .appendingPathComponent(sessionID, isDirectory: true)
            .appendingPathComponent("\(sessionID).json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        try Self.requireSafeContainedRegularFile(manifestURL, within: sessionsRoot)
        let data = try Self.readBoundedData(manifestURL, limit: Self.manifestByteLimit)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (object["version"] as? NSNumber)?.intValue == 1,
              let id = Self.nonEmptyString(object["session_id"]), id == sessionID,
              let startedRaw = Self.nonEmptyString(object["started_at"]),
              let startedAt = Self.isoDate(startedRaw),
              let cwdRaw = Self.nonEmptyString(object["cwd"]),
              let workspaceRaw = Self.nonEmptyString(object["workspace_root"]),
              let cwd = Self.absoluteProjectPath(workspaceRaw)
                ?? Self.absoluteProjectPath(cwdRaw) else {
            throw ClineReaderError.malformedManifest(manifestURL.path)
        }
        let endedAt = Self.nonEmptyString(object["ended_at"]).flatMap(Self.isoDate)
        let prompt = Self.nonEmptyString(object["prompt"])
        let metadata = object["metadata"] as? [String: Any]
        return Record(
            id: id, cwd: cwd, startedAt: startedAt, updatedAt: endedAt ?? startedAt,
            prompt: prompt, title: Self.nonEmptyString(metadata?["title"]),
            messagesPath: Self.nonEmptyString(object["messages_path"]),
            sourcePath: JSONLStreamReader.canonicalPath(manifestURL.path)
        )
    }

    private func loadMessages(_ record: Record) throws -> SessionDetail {
        guard let rawPath = record.messagesPath,
              (rawPath as NSString).isAbsolutePath else {
            throw ClineReaderError.messagesMissing(record.id)
        }
        let messagesURL = URL(fileURLWithPath: (rawPath as NSString).standardizingPath)
        guard FileManager.default.fileExists(atPath: messagesURL.path) else {
            throw ClineReaderError.messagesMissing(record.id)
        }
        try Self.requireSafeContainedRegularFile(messagesURL, within: sessionsRoot)
        let expectedURL = sessionsRoot
            .appendingPathComponent(record.id, isDirectory: true)
            .appendingPathComponent("\(record.id).messages.json")
        guard messagesURL.resolvingSymlinksInPath().standardizedFileURL.path
                == expectedURL.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw ClineReaderError.unsafeFile(messagesURL.path, "session")
        }
        let data = try Self.readBoundedData(messagesURL, limit: maxDetailBytes)
        let parsed = try JSONSerialization.jsonObject(with: data)
        let rawMessages: [Any]
        if let messages = parsed as? [Any] {
            rawMessages = messages
        } else if let envelope = parsed as? [String: Any],
                  let messages = envelope["messages"] as? [Any] {
            rawMessages = messages
        } else {
            throw ClineReaderError.malformedMessages(messagesURL.path)
        }

        var isTruncated = rawMessages.count > maxDetailMessages
        var remaining = maxDetailCharacters
        var result: [SessionMessage] = []
        for raw in rawMessages.suffix(maxDetailMessages).reversed() {
            try Task.checkCancellation()
            guard remaining > 0 else { isTruncated = true; break }
            guard let message = raw as? [String: Any],
                  let roleRaw = Self.nonEmptyString(message["role"]),
                  let role = Self.role(roleRaw),
                  let rawText = Self.messageText(message["content"]) else { continue }
            let displayText = role == .user ? Self.formatUserInput(rawText) : rawText
            guard !displayText.isEmpty else { continue }
            var text = displayText
            if text.count > Self.perMessageCharacterLimit {
                text = String(text.prefix(Self.perMessageCharacterLimit))
                isTruncated = true
            }
            if text.count > remaining {
                text = String(text.suffix(remaining))
                isTruncated = true
            }
            remaining -= text.count
            let timestamp = Self.messageDate(message["ts"]) ?? record.startedAt
            result.append(SessionMessage(role: role, content: text, timestamp: timestamp))
        }
        return SessionDetail(
            tool: toolId, toolSessionId: record.id, cwd: record.cwd,
            startedAt: record.startedAt, messages: result.reversed(),
            isTruncated: isTruncated
        )
    }

    private static func discoveredSession(_ record: Record) -> DiscoveredSession {
        let prompt = record.prompt.flatMap(formatUserInput)
        let title = record.title.flatMap { SessionDisplayText.title(from: $0) }
            ?? prompt.flatMap { SessionDisplayText.title(from: $0) }
        let preview = prompt.flatMap { SessionDisplayText.preview(from: $0) }
            ?? title ?? ""
        return DiscoveredSession(
            tool: "cline", toolSessionId: record.id, sourcePath: record.sourcePath,
            projectCwd: record.cwd, startedAt: record.startedAt,
            updatedAt: record.updatedAt, messageCount: -1,
            title: title, preview: preview
        )
    }

    private static func role(_ raw: String) -> MessageRole? {
        switch raw.lowercased() {
        case "user": return .user
        case "assistant": return .assistant
        default: return nil
        }
    }

    private static func messageText(_ content: Any?) -> String? {
        if let string = nonEmptyString(content) { return string }
        guard let blocks = content as? [Any] else { return nil }
        let text = blocks.compactMap { block -> String? in
            guard let object = block as? [String: Any],
                  object["type"] as? String == "text" else { return nil }
            return nonEmptyString(object["text"])
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    /// Mirrors Cline's display formatting for its durable user-input envelope.
    private static func formatUserInput(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        value = removingElements(named: "mode_notice", from: value)
        for tag in ["user_input", "user_command"] {
            if let openEnd = value.range(of: ">"),
               value[..<openEnd.lowerBound].lowercased().hasPrefix("<\(tag)"),
               let close = value.range(of: "</\(tag)>", options: .caseInsensitive) {
                value = String(value[openEnd.upperBound..<close.lowerBound])
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removingElements(named tag: String, from input: String) -> String {
        var value = input
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        while let start = value.range(of: open, options: .caseInsensitive),
              let end = value.range(
                of: close, options: .caseInsensitive, range: start.upperBound..<value.endIndex
              ) {
            value.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return value
    }

    private static func configuredDirectory(_ raw: String?, fallback: URL) -> URL {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return fallback }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
    }

    private static func normalizedKnownFiles(_ files: [String: Date]) -> [String: Date] {
        var result: [String: Date] = [:]
        for (path, indexedAt) in files {
            let normalized = JSONLStreamReader.canonicalPath(path)
            result[normalized] = max(result[normalized] ?? .distantPast, indexedAt)
        }
        return result
    }

    private static func openDatabase(_ url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        guard result == SQLITE_OK, let database else {
            let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let database { sqlite3_close(database) }
            throw ClineReaderError.databaseOpenFailed(url.path, detail)
        }
        sqlite3_busy_timeout(database, 250)
        return database
    }

    private static func validateSchema(_ database: OpaquePointer, path: String) throws {
        let required: Set<String> = [
            "session_id", "started_at", "updated_at", "cwd", "workspace_root",
            "parent_session_id", "is_subagent", "prompt", "metadata_json", "messages_path"
        ]
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(sessions)", -1, &statement, nil)
                == SQLITE_OK,
              let statement else {
            throw ClineReaderError.queryFailed(path, String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = nonEmptyText(statement, column: 1) { columns.insert(name) }
        }
        let missing = required.subtracting(columns).sorted()
        guard missing.isEmpty else { throw ClineReaderError.unsupportedSchema(path, missing) }
    }

    private static func bind(
        _ value: String, to statement: OpaquePointer, index: Int32,
        database: OpaquePointer
    ) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
        guard result == SQLITE_OK else {
            throw ClineReaderError.queryFailed("sessions", String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func nonEmptyText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        nonEmptyText(statement, column: column)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func metadataTitle(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return nonEmptyString(object["title"])
    }

    private static func isoDate(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    private static func messageDate(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite, raw >= 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
    }

    private static func absoluteProjectPath(_ raw: String) -> String? {
        guard (raw as NSString).isAbsolutePath else { return nil }
        return (raw as NSString).standardizingPath
    }

    private static func isSafeSessionID(_ id: String) -> Bool {
        !id.isEmpty && id != "." && id != ".." && !id.contains("/") && !id.contains(":")
            && !id.contains("\\") && id.utf8.count <= 255
    }

    private static func readBoundedData(_ url: URL, limit: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= limit else {
            throw ClineReaderError.fileTooLarge(url.path, limit)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ClineReaderError.fileTooLarge(url.path, limit) }
        return data
    }

    private static func requireSafeRegularFile(_ url: URL, label: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ClineReaderError.unsafeFile(url.path, label)
        }
    }

    private static func requireSafeContainedRegularFile(_ url: URL, within root: URL) throws {
        try requireSafeRegularFile(url, label: "session")
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedFile = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedFile.hasPrefix(resolvedRoot + "/") else {
            throw ClineReaderError.unsafeFile(url.path, "session")
        }
    }

    private static func latestSQLiteModificationDate(_ url: URL) -> Date {
        [url, URL(fileURLWithPath: url.path + "-wal")].compactMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }.max() ?? .distantPast
    }
}

public enum ClineReaderError: LocalizedError, Sendable, Equatable {
    case databaseOpenFailed(String, String)
    case unsupportedSchema(String, [String])
    case malformedRecord(String, Int)
    case malformedManifest(String)
    case malformedMessages(String)
    case queryFailed(String, String)
    case sessionNotFound(String)
    case messagesMissing(String)
    case fileTooLarge(String, Int)
    case unsafeFile(String, String)

    public var errorDescription: String? {
        switch self {
        case let .databaseOpenFailed(path, detail):
            return "Cline 数据库无法以只读方式打开：\(path)（\(detail)）"
        case let .unsupportedSchema(path, columns):
            return "Cline 数据库格式不受支持：\(path)（缺少字段：\(columns.joined(separator: ", "))）"
        case let .malformedRecord(path, row):
            return "Cline 数据库包含无效会话记录：\(path)（第 \(row) 行）"
        case let .malformedManifest(path):
            return "Cline 会话清单格式无效：\(path)"
        case let .malformedMessages(path):
            return "Cline 会话消息格式无效：\(path)"
        case let .queryFailed(path, detail):
            return "读取 Cline 会话数据失败：\(path)（\(detail)）"
        case let .sessionNotFound(id):
            return "未找到 Cline 会话：\(id)"
        case let .messagesMissing(id):
            return "Cline 会话没有可读取的消息文件：\(id)"
        case let .fileTooLarge(path, limit):
            return "Cline 会话文件超过安全读取上限：\(path)（\(limit) 字节）"
        case let .unsafeFile(path, label):
            return "拒绝读取不安全的 Cline \(label) 文件：\(path)"
        }
    }
}
