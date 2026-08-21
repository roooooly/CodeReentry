import Foundation
import SQLite3

/// Metadata-only discovery for OpenCode v1.18.19 SQLite session storage.
///
/// OpenCode stores its default database at
/// `~/.local/share/opencode/opencode.db`. DevHub opens candidate databases with
/// `SQLITE_OPEN_READONLY`, validates the named schema before querying it, and
/// never reads message bodies. Discovery only runs through the app's explicit
/// refresh action.
public struct OpenCodeReader: SessionReader {
    public let toolId = "opencode"

    private static let databaseLimit = 8
    private static let sessionLimitPerDatabase = 1_000
    private let databaseURLs: [URL]
    private let maxDatabases: Int
    private let maxSessionsPerDatabase: Int

    public init(
        databaseURLs: [URL]? = nil,
        homeURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxDatabases: Int = 8,
        maxSessionsPerDatabase: Int = 1_000
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
        throw OpenCodeReaderError.conversationUnavailable(id)
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
                messageCount: 0,
                title: title,
                preview: title
            ))
        }
        return sessions
    }

    private func validateSchema(database: OpaquePointer, path: String) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(session)", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw OpenCodeReaderError.queryFailed(path, String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var columns: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = Self.nonEmptyText(statement, column: 1) { columns.insert(name) }
        }
        let required: Set<String> = [
            "id", "directory", "title", "time_created", "time_updated", "time_archived"
        ]
        let missing = required.subtracting(columns).sorted()
        guard missing.isEmpty else {
            throw OpenCodeReaderError.unsupportedSchema(path, missing)
        }
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
    case queryFailed(String, String)
    case conversationUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .databaseOpenFailed(let path, let detail):
            return "OpenCode 数据库无法以只读方式打开：\(path)（\(detail)）"
        case .unsupportedSchema(let path, let columns):
            return "OpenCode 数据库格式不受支持：\(path)（缺少字段：\(columns.joined(separator: ", "))）"
        case .malformedRecord(let path, let row):
            return "OpenCode 数据库包含无效会话记录：\(path)（第 \(row) 行）"
        case .queryFailed(let path, let detail):
            return "读取 OpenCode 会话元数据失败：\(path)（\(detail)）"
        case .conversationUnavailable:
            return "DevHub 当前只索引 OpenCode 会话元数据；请在 OpenCode 中继续该会话。"
        }
    }
}
