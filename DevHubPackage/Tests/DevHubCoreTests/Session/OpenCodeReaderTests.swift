import Foundation
import SQLite3
import Testing
@testable import DevHubCore

@Suite("OpenCodeReader")
struct OpenCodeReaderTests {
    @Test("discovers current unarchived session metadata without reading messages")
    func discoversMetadata() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        try fixture.execute("""
            INSERT INTO session VALUES
              ('ses_new', '/Projects/app', 'Fix checkout flow', 1700000000000, 1700000300000, NULL),
              ('ses_old', '/Projects/lib', 'Refactor parser', 1699990000000, 1699990100000, NULL),
              ('ses_archived', '/Projects/old', 'Archived work', 1600000000000, 1600000100000, 1700000400000)
            """)

        let sessions = try await OpenCodeReader(databaseURLs: [fixture.databaseURL]).discover()

        #expect(sessions.map(\.toolSessionId) == ["ses_new", "ses_old"])
        #expect(sessions[0].tool == "opencode")
        #expect(sessions[0].projectCwd == "/Projects/app")
        #expect(sessions[0].title == "Fix checkout flow")
        #expect(sessions[0].messageCount == -1)
        #expect(sessions[0].sourcePath == fixture.databaseURL.path)
        #expect(sessions[0].updatedAt == Date(timeIntervalSince1970: 1_700_000_300))
    }

    @Test("discovery is bounded and incremental")
    func boundedAndIncremental() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        try fixture.execute("""
            INSERT INTO session VALUES
              ('one', '/p', 'One', 1000, 3000, NULL),
              ('two', '/p', 'Two', 1000, 2000, NULL),
              ('three', '/p', 'Three', 1000, 1000, NULL)
            """)
        let reader = OpenCodeReader(
            databaseURLs: [fixture.databaseURL],
            maxSessionsPerDatabase: 2
        )

        let first = try await reader.discover()
        #expect(first.map(\.toolSessionId) == ["one", "two"])

        let unchanged = try await reader.discover(knownFiles: [
            fixture.databaseURL.path: .distantFuture
        ])
        #expect(unchanged.isEmpty)
    }

    @Test("caller-provided limits cannot disable the hard session bound")
    func hardBound() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        let values = (0..<1_005).map { index in
            "('s\(index)', '/p', 'Session \(index)', 1000, \(index + 1), NULL)"
        }.joined(separator: ",")
        try fixture.execute("INSERT INTO session VALUES \(values)")

        let sessions = try await OpenCodeReader(
            databaseURLs: [fixture.databaseURL],
            maxSessionsPerDatabase: .max
        ).discover()

        #expect(sessions.count == 1_000)
    }

    @Test("unsupported schema fails explicitly")
    func unsupportedSchema() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute("CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT NOT NULL)")
        let reader = OpenCodeReader(databaseURLs: [fixture.databaseURL])

        await #expect(throws: OpenCodeReaderError.self) {
            _ = try await reader.discover()
        }
    }

    @Test("malformed row fails explicitly")
    func malformedRecord() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        try fixture.execute("""
            INSERT INTO session VALUES
              ('bad', '', 'Missing directory', 1700000000000, 1700000300000, NULL)
            """)
        let reader = OpenCodeReader(databaseURLs: [fixture.databaseURL])

        await #expect(throws: OpenCodeReaderError.malformedRecord(fixture.databaseURL.path, 1)) {
            _ = try await reader.discover()
        }
    }

    @Test("a cancelled refresh stops before opening databases")
    func cancellable() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        let reader = OpenCodeReader(databaseURLs: [fixture.databaseURL])
        let task = Task {
            try Task.checkCancellation()
            return try await reader.discover()
        }
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test("loads bounded text and tool parts while excluding reasoning")
    func loadsConversation() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        try fixture.execute(Self.conversationSchema)
        try fixture.execute("""
            INSERT INTO session VALUES
              ('ses_1', '/Projects/app', 'Fix checkout flow', 1700000000000, 1700000400000, NULL)
            """)
        try fixture.execute("""
            INSERT INTO message VALUES
              ('msg_user', 'ses_1', 1700000001000, 1700000001000,
               '{"role":"user","time":{"created":1700000001000}}'),
              ('msg_assistant', 'ses_1', 1700000002000, 1700000002000,
               '{"role":"assistant","time":{"created":1700000002000}}')
            """)
        try fixture.execute("""
            INSERT INTO part VALUES
              ('prt_user', 'msg_user', 'ses_1', 1700000001000, 1700000001000,
               '{"type":"text","text":"Fix the checkout flow"}'),
              ('prt_reasoning', 'msg_assistant', 'ses_1', 1700000002000, 1700000002000,
               '{"type":"reasoning","text":"private chain of thought"}'),
              ('prt_answer', 'msg_assistant', 'ses_1', 1700000003000, 1700000003000,
               '{"type":"text","text":"I found the failing redirect."}'),
              ('prt_tool', 'msg_assistant', 'ses_1', 1700000004000, 1700000004000,
               '{"type":"tool","tool":"bash","state":{"status":"completed","input":{"command":"swift test"},"title":"Run tests","output":"ok"}}')
            """)

        let detail = try await OpenCodeReader(databaseURLs: [fixture.databaseURL]).load("ses_1")

        #expect(detail.tool == "opencode")
        #expect(detail.cwd == "/Projects/app")
        #expect(detail.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(detail.messages.map(\.role) == [.user, .assistant, .tool])
        #expect(detail.messages[0].content == "Fix the checkout flow")
        #expect(detail.messages[1].content == "I found the failing redirect.")
        #expect(detail.messages[2].toolName == "bash")
        #expect(detail.messages[2].toolInput?.contains("swift test") == true)
        #expect(detail.messages.allSatisfy { !$0.content.contains("chain of thought") })
        #expect(!detail.isTruncated)
    }

    @Test("detail loading retains only the newest bounded messages")
    func boundedConversation() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        try fixture.execute(Self.conversationSchema)
        try fixture.execute("""
            INSERT INTO session VALUES
              ('ses_1', '/Projects/app', 'Long session', 1000, 4000, NULL)
            """)
        try fixture.execute("""
            INSERT INTO message VALUES
              ('msg_1', 'ses_1', 1000, 1000, '{"role":"user"}'),
              ('msg_2', 'ses_1', 2000, 2000, '{"role":"assistant"}')
            """)
        try fixture.execute("""
            INSERT INTO part VALUES
              ('prt_1', 'msg_1', 'ses_1', 1000, 1000, '{"type":"text","text":"old"}'),
              ('prt_2', 'msg_2', 'ses_1', 2000, 2000, '{"type":"text","text":"new"}')
            """)

        let detail = try await OpenCodeReader(
            databaseURLs: [fixture.databaseURL],
            maxDetailMessages: 1
        ).load("ses_1")

        #expect(detail.messages.map(\.content) == ["new"])
        #expect(detail.isTruncated)
    }

    @Test("caller-provided limits cannot raise the hard detail message bound")
    func hardConversationBound() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        try fixture.execute(Self.conversationSchema)
        try fixture.execute("""
            INSERT INTO session VALUES
              ('ses_1', '/Projects/app', 'Very long session', 1000, 9999, NULL)
            """)
        let messages = (1...501).map { index in
            "('msg_\(index)', 'ses_1', \(index), \(index), '{\"role\":\"user\"}')"
        }.joined(separator: ",")
        let parts = (1...501).map { index in
            "('prt_\(index)', 'msg_\(index)', 'ses_1', \(index), \(index), "
                + "'{\"type\":\"text\",\"text\":\"message \(index)\"}')"
        }.joined(separator: ",")
        try fixture.execute("INSERT INTO message VALUES \(messages)")
        try fixture.execute("INSERT INTO part VALUES \(parts)")

        let detail = try await OpenCodeReader(
            databaseURLs: [fixture.databaseURL],
            maxDetailMessages: .max,
            maxDetailParts: .max,
            maxDetailCharacters: .max
        ).load("ses_1")

        #expect(detail.messages.count == 500)
        #expect(detail.messages.first?.content == "message 2")
        #expect(detail.messages.last?.content == "message 501")
        #expect(detail.isTruncated)
    }

    @Test("detail loading enforces the total character budget")
    func boundedConversationCharacters() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        try fixture.execute(Self.conversationSchema)
        try fixture.execute("""
            INSERT INTO session VALUES
              ('ses_1', '/Projects/app', 'Long text', 1000, 2000, NULL)
            """)
        try fixture.execute("""
            INSERT INTO message VALUES
              ('msg_1', 'ses_1', 1000, 1000, '{"role":"user"}'),
              ('msg_2', 'ses_1', 2000, 2000, '{"role":"assistant"}')
            """)
        try fixture.execute("""
            INSERT INTO part VALUES
              ('prt_1', 'msg_1', 'ses_1', 1000, 1000, '{"type":"text","text":"older"}'),
              ('prt_2', 'msg_2', 'ses_1', 2000, 2000, '{"type":"text","text":"abcdefghij"}')
            """)

        let detail = try await OpenCodeReader(
            databaseURLs: [fixture.databaseURL],
            maxDetailCharacters: 5
        ).load("ses_1")

        #expect(detail.messages.map(\.content) == ["abcde"])
        #expect(detail.isTruncated)
    }

    @Test("oversized JSON cells are omitted before decoding")
    func boundedConversationJSON() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        try fixture.execute(Self.conversationSchema)
        try fixture.execute("""
            INSERT INTO session VALUES
              ('ses_1', '/Projects/app', 'Large JSON', 1000, 2000, NULL)
            """)
        try fixture.execute("""
            INSERT INTO message VALUES
              ('msg_1', 'ses_1', 1000, 1000, '{"role":"user"}')
            """)
        try fixture.execute("""
            INSERT INTO part VALUES
              ('prt_1', 'msg_1', 'ses_1', 1000, 1000,
               '{"type":"text","text":"This payload is deliberately larger than thirty bytes."}')
            """)

        let detail = try await OpenCodeReader(
            databaseURLs: [fixture.databaseURL],
            maxDetailJSONBytes: 30
        ).load("ses_1")

        #expect(detail.messages.isEmpty)
        #expect(detail.isTruncated)
    }

    @Test("missing conversation tables fail explicitly for a known session")
    func missingConversationSchema() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)
        try fixture.execute("""
            INSERT INTO session VALUES
              ('ses_1', '/Projects/app', 'Known session', 1000, 2000, NULL)
            """)

        await #expect(throws: OpenCodeReaderError.unsupportedSchema(
            fixture.databaseURL.path,
            ["message.data", "message.id", "message.session_id", "message.time_created"]
        )) {
            _ = try await OpenCodeReader(databaseURLs: [fixture.databaseURL]).load("ses_1")
        }
    }

    @Test("missing session fails explicitly")
    func missingConversation() async throws {
        let fixture = try SQLiteFixture()
        try fixture.execute(Self.currentSchema)

        await #expect(throws: OpenCodeReaderError.sessionNotFound("missing")) {
            _ = try await OpenCodeReader(databaseURLs: [fixture.databaseURL]).load("missing")
        }
    }

    @Test("default path honors OPENCODE_DB before standard and channel databases")
    func standardPaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenCodeReaderPaths-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let standardDirectory = root.appendingPathComponent(".local/share/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: standardDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: standardDirectory.appendingPathComponent("opencode-beta.db").path,
            contents: Data()
        )
        let custom = root.appendingPathComponent("custom.db")

        let paths = OpenCodeReader.standardDatabaseURLs(
            homeURL: root,
            environment: ["OPENCODE_DB": custom.path],
            maxDatabases: 8
        )

        #expect(paths.map(\.lastPathComponent) == ["custom.db", "opencode.db", "opencode-beta.db"])
    }

    private static let currentSchema = """
        CREATE TABLE session (
          id TEXT PRIMARY KEY,
          directory TEXT NOT NULL,
          title TEXT NOT NULL,
          time_created INTEGER NOT NULL,
          time_updated INTEGER NOT NULL,
          time_archived INTEGER
        )
        """

    private static let conversationSchema = """
        CREATE TABLE message (
          id TEXT PRIMARY KEY,
          session_id TEXT NOT NULL,
          time_created INTEGER NOT NULL,
          time_updated INTEGER NOT NULL,
          data TEXT NOT NULL
        );
        CREATE TABLE part (
          id TEXT PRIMARY KEY,
          message_id TEXT NOT NULL,
          session_id TEXT NOT NULL,
          time_created INTEGER NOT NULL,
          time_updated INTEGER NOT NULL,
          data TEXT NOT NULL
        );
        """
}

private final class SQLiteFixture {
    let directoryURL: URL
    let databaseURL: URL

    init() throws {
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevHub-OpenCode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        databaseURL = directoryURL.appendingPathComponent("opencode.db")
    }

    deinit {
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite("open failed")
        }
        defer { sqlite3_close(database) }
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw FixtureError.sqlite(message)
        }
    }
}

private enum FixtureError: Error {
    case sqlite(String)
}
