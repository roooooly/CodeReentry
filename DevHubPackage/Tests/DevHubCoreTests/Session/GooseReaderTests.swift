import Foundation
import SQLite3
import Testing
@testable import DevHubCore

@Suite("GooseReader")
struct GooseReaderTests {
    @Test("discovers only current user sessions from metadata")
    func discoversMetadata() async throws {
        let fixture = try GooseSQLiteFixture()
        try fixture.execute(Self.schema)
        try fixture.execute("""
            INSERT INTO sessions VALUES
              ('20260820_1', 'Fix checkout', '', 'user', '/Projects/app',
               '2026-08-20 10:00:00', '2026-08-20 10:05:00'),
              ('20260819_1', '', 'Refactor parser', 'user', '/Projects/lib',
               '2026-08-19 09:00:00', '2026-08-19 09:02:00'),
              ('child', 'Subagent', '', 'sub_agent', '/Projects/app',
               '2026-08-20 10:01:00', '2026-08-20 10:04:00')
            """)

        let sessions = try await GooseReader(databaseURL: fixture.databaseURL).discover()

        #expect(sessions.map(\.toolSessionId) == ["20260820_1", "20260819_1"])
        #expect(sessions[0].tool == "goose")
        #expect(sessions[0].projectCwd == "/Projects/app")
        #expect(sessions[0].title == "Fix checkout")
        #expect(sessions[1].title == "Refactor parser")
        #expect(sessions[0].messageCount == -1)
        #expect(sessions[0].sourcePath == fixture.databaseURL.path)
    }

    @Test("discovery is bounded and incremental")
    func boundedAndIncremental() async throws {
        let fixture = try GooseSQLiteFixture()
        try fixture.execute(Self.schema)
        try fixture.execute("""
            INSERT INTO sessions VALUES
              ('one', 'One', '', 'user', '/p', '2026-01-01', '2026-01-03'),
              ('two', 'Two', '', 'user', '/p', '2026-01-01', '2026-01-02'),
              ('three', 'Three', '', 'user', '/p', '2026-01-01', '2026-01-01')
            """)
        let reader = GooseReader(databaseURL: fixture.databaseURL, maxSessions: 2)
        #expect(try await reader.discover().map(\.toolSessionId) == ["one", "two"])
        #expect(try await reader.discover(knownFiles: [
            fixture.databaseURL.path: .distantFuture
        ]).isEmpty)
    }

    @Test("caller cannot raise the hard discovery bound")
    func hardDiscoveryBound() async throws {
        let fixture = try GooseSQLiteFixture()
        try fixture.execute(Self.schema)
        let values = (0..<1_005).map { index in
            "('s\(index)', 'S', '', 'user', '/p', '2026-01-01', '2026-01-01')"
        }.joined(separator: ",")
        try fixture.execute("INSERT INTO sessions VALUES \(values)")
        let sessions = try await GooseReader(
            databaseURL: fixture.databaseURL, maxSessions: .max
        ).discover()
        #expect(sessions.count == 1_000)
    }

    @Test("loads visible text while excluding hidden, tool and thinking content")
    func loadsVisibleConversation() async throws {
        let fixture = try GooseSQLiteFixture()
        try fixture.execute(Self.schema)
        try fixture.execute(Self.messagesSchema)
        try fixture.execute("""
            INSERT INTO sessions VALUES
              ('20260820_1', 'Fix checkout', '', 'user', '/Projects/app',
               '2026-08-20 10:00:00', '2026-08-20 10:05:00')
            """)
        try fixture.execute("""
            INSERT INTO messages (session_id, role, content_json, created_timestamp, metadata_json) VALUES
              ('20260820_1', 'user',
               '[{"type":"text","text":"Fix checkout"},{"type":"image","data":"private"}]',
               1787191201, '{}'),
              ('20260820_1', 'assistant',
               '[{"type":"thinking","thinking":"private reasoning","signature":"x"},{"type":"text","text":"The redirect is fixed."},{"type":"toolRequest","id":"t1"}]',
               1787191202000, '{"userVisible":true}'),
              ('20260820_1', 'assistant',
               '[{"type":"text","text":"hidden summary"}]',
               1787191203, '{"userVisible":false}'),
              ('20260820_1', 'assistant',
               '[{"type":"toolResponse","toolResult":{"Ok":{"content":[]}}}]',
               1787191204, NULL)
            """)

        let detail = try await GooseReader(databaseURL: fixture.databaseURL).load("20260820_1")

        #expect(detail.tool == "goose")
        #expect(detail.cwd == "/Projects/app")
        #expect(detail.messages.map(\.role) == [.user, .assistant])
        #expect(detail.messages.map(\.content) == ["Fix checkout", "The redirect is fixed."])
        #expect(detail.messages.allSatisfy { !$0.content.contains("private") })
        #expect(!detail.isTruncated)
    }

    @Test("detail retains newest bounded context and enforces text budget")
    func boundedDetail() async throws {
        let fixture = try GooseSQLiteFixture()
        try fixture.execute(Self.schema)
        try fixture.execute(Self.messagesSchema)
        try fixture.execute("""
            INSERT INTO sessions VALUES
              ('s1', 'Long', '', 'user', '/p', '2026-01-01', '2026-01-02')
            """)
        try fixture.execute("""
            INSERT INTO messages (session_id, role, content_json, created_timestamp, metadata_json) VALUES
              ('s1', 'user', '[{"type":"text","text":"old"}]', 1, '{}'),
              ('s1', 'assistant', '[{"type":"text","text":"abcdefghij"}]', 2, '{}')
            """)
        let detail = try await GooseReader(
            databaseURL: fixture.databaseURL,
            maxMessages: 1,
            maxCharacters: 5
        ).load("s1")
        #expect(detail.messages.map(\.content) == ["abcde"])
        #expect(detail.isTruncated)
    }

    @Test("oversized or malformed JSON never reaches the conversation")
    func rejectsUnsafeJSON() async throws {
        let fixture = try GooseSQLiteFixture()
        try fixture.execute(Self.schema)
        try fixture.execute(Self.messagesSchema)
        try fixture.execute("""
            INSERT INTO sessions VALUES
              ('s1', 'Unsafe', '', 'user', '/p', '2026-01-01', '2026-01-02')
            """)
        try fixture.execute("""
            INSERT INTO messages (session_id, role, content_json, created_timestamp, metadata_json) VALUES
              ('s1', 'user', '[{"type":"text","text":"payload larger than thirty bytes"}]', 1, '{}'),
              ('s1', 'assistant', 'not-json', 2, '{}'),
              ('s1', 'assistant', '[{"type":"text","text":"bad metadata"}]', 3, 'not-json')
            """)
        let detail = try await GooseReader(
            databaseURL: fixture.databaseURL, maxJSONBytes: 30
        ).load("s1")
        #expect(detail.messages.isEmpty)
        #expect(detail.isTruncated)
    }

    @Test("path override must be absolute and uses Goose data layout")
    func standardPath() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        #expect(GooseReader.standardDatabaseURL(
            homeURL: home, environment: [:]
        ).path == "/Users/test/Library/Application Support/Block/goose/sessions/sessions.db")
        #expect(GooseReader.standardDatabaseURL(
            homeURL: home, environment: ["GOOSE_PATH_ROOT": "/tmp/goose"]
        ).path == "/tmp/goose/data/sessions/sessions.db")
        #expect(GooseReader.standardDatabaseURL(
            homeURL: home, environment: ["GOOSE_PATH_ROOT": "relative"]
        ).path == "/Users/test/Library/Application Support/Block/goose/sessions/sessions.db")
    }

    @Test("unsupported schemas and unknown sessions fail explicitly")
    func explicitFailures() async throws {
        let fixture = try GooseSQLiteFixture()
        try fixture.execute("CREATE TABLE sessions (id TEXT PRIMARY KEY)")
        await #expect(throws: GooseReaderError.self) {
            _ = try await GooseReader(databaseURL: fixture.databaseURL).discover()
        }

        let complete = try GooseSQLiteFixture()
        try complete.execute(Self.schema)
        try complete.execute(Self.messagesSchema)
        await #expect(throws: GooseReaderError.sessionNotFound("missing")) {
            _ = try await GooseReader(databaseURL: complete.databaseURL).load("missing")
        }
    }

    private static let schema = """
        CREATE TABLE sessions (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL DEFAULT '',
          description TEXT NOT NULL DEFAULT '',
          session_type TEXT NOT NULL DEFAULT 'user',
          working_dir TEXT NOT NULL,
          created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        )
        """

    private static let messagesSchema = """
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          role TEXT NOT NULL,
          content_json TEXT NOT NULL,
          created_timestamp INTEGER NOT NULL,
          metadata_json TEXT
        )
        """
}

private final class GooseSQLiteFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeReentry-Goose-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        databaseURL = directoryURL.appendingPathComponent("sessions.db")
    }

    deinit { try? FileManager.default.removeItem(at: directoryURL) }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw GooseFixtureError.sqlite("open failed")
        }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw GooseFixtureError.sqlite(detail)
        }
    }
}

private enum GooseFixtureError: Error { case sqlite(String) }
