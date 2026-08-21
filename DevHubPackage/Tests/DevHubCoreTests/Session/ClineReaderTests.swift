import Foundation
import SQLite3
import Testing
@testable import DevHubCore

@Suite("ClineReader")
struct ClineReaderTests {
    @Test("discovers root sessions from the read-only database")
    func discoversDatabaseSessions() async throws {
        let fixture = try ClineFixture()
        defer { fixture.remove() }
        try fixture.insertSession(
            id: "root-1", workspace: "/tmp/Cline Project",
            prompt: "<user_input mode=\"act\">Fix the cache race</user_input>",
            metadata: #"{"title":"Cache repair"}"#
        )
        try fixture.insertSession(
            id: "child-1", workspace: "/tmp/Cline Project", prompt: "hidden",
            parent: "root-1", isSubagent: true
        )

        let sessions = try await fixture.reader.discover()

        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.tool == "cline")
        #expect(session.toolSessionId == "root-1")
        #expect(session.projectCwd == "/tmp/Cline Project")
        #expect(session.title == "Cache repair")
        #expect(session.preview == "Fix the cache race")
        #expect(session.messageCount == -1)
        #expect(session.sourcePath == fixture.databaseURL.path)
    }

    @Test("loads only bounded user and assistant display text")
    func loadsConversationText() async throws {
        let fixture = try ClineFixture()
        defer { fixture.remove() }
        let messages = fixture.messagesURL(id: "root-1")
        try fixture.writeJSON([
            "version": 1,
            "updated_at": "2026-08-21T10:10:00.000Z",
            "messages": [
                [
                    "role": "user", "ts": 1_777_000_000_000 as NSNumber,
                    "content": [["type": "text", "text": "<user_input mode=\"act\"><mode_notice>internal</mode_notice>Inspect auth</user_input>"], ["type": "file", "data": "secret file"]]
                ],
                [
                    "role": "assistant", "ts": 1_777_000_001_000 as NSNumber,
                    "content": [["type": "thinking", "thinking": "private reasoning"], ["type": "text", "text": "The token expires early."]]
                ],
                ["role": "tool", "content": "tool output"],
                ["role": "user", "content": [["type": "image", "data": "base64"]]]
            ]
        ], to: messages)
        try fixture.insertSession(
            id: "root-1", workspace: "/tmp/Cline Project", prompt: "Inspect auth",
            messagesPath: messages.path
        )

        let detail = try await fixture.reader.load("root-1")

        #expect(detail.cwd == "/tmp/Cline Project")
        #expect(detail.messages.map(\.role) == [.user, .assistant])
        #expect(detail.messages.map(\.content) == ["Inspect auth", "The token expires early."])
        #expect(!detail.messages.map(\.content).joined().contains("secret"))
        #expect(!detail.messages.map(\.content).joined().contains("reasoning"))
        #expect(!detail.isTruncated)
    }

    @Test("keeps newest context within message and character budgets")
    func boundsDetail() async throws {
        let fixture = try ClineFixture()
        defer { fixture.remove() }
        let messages = fixture.messagesURL(id: "bounded")
        try fixture.writeJSON([
            "messages": [
                ["role": "user", "content": "old context"],
                ["role": "assistant", "content": "middle context"],
                ["role": "user", "content": "newest context"]
            ]
        ], to: messages)
        try fixture.insertSession(
            id: "bounded", workspace: "/tmp/Bounded", prompt: "old context",
            messagesPath: messages.path
        )
        let reader = ClineReader(
            databaseURL: fixture.databaseURL, sessionsRoot: fixture.sessionsRoot,
            maxDetailMessages: 2, maxDetailCharacters: 16
        )

        let detail = try await reader.load("bounded")

        #expect(detail.messages.last?.content == "newest context")
        #expect(detail.messages.count == 2)
        #expect(detail.isTruncated)
    }

    @Test("falls back to the official manifest layout when the database is absent")
    func manifestFallback() async throws {
        let fixture = try ClineFixture(createDatabase: false)
        defer { fixture.remove() }
        let messages = fixture.messagesURL(id: "manifest-1")
        try fixture.writeJSON([
            "messages": [["role": "user", "content": "Resume from manifest"]]
        ], to: messages)
        try fixture.writeManifest(
            id: "manifest-1", workspace: "/tmp/Manifest", prompt: "Resume from manifest",
            messagesPath: messages.path
        )

        let sessions = try await fixture.reader.discover()
        let detail = try await fixture.reader.load("manifest-1")

        #expect(sessions.map(\.toolSessionId) == ["manifest-1"])
        #expect(sessions.first?.sourcePath.hasSuffix("manifest-1/manifest-1.json") == true)
        #expect(detail.messages.map(\.content) == ["Resume from manifest"])
    }

    @Test("honors Cline storage overrides")
    func storageOverrides() {
        let home = URL(fileURLWithPath: "/tmp/home", isDirectory: true)
        let reader = ClineReader(homeURL: home, environment: [
            "CLINE_DATA_DIR": "/tmp/cline-data",
            "CLINE_DB_DATA_DIR": "/tmp/cline-db",
            "CLINE_SESSION_DATA_DIR": "/tmp/cline-sessions"
        ])

        #expect(reader.databaseURL.path == "/tmp/cline-db/sessions.db")
        #expect(reader.sessionsRoot.path == "/tmp/cline-sessions")
    }

    @Test("rejects message paths outside the session root and symbolic links")
    func rejectsUnsafeMessagePaths() async throws {
        let fixture = try ClineFixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside.messages.json")
        try fixture.writeJSON(["messages": []], to: outside)
        try fixture.insertSession(
            id: "outside", workspace: "/tmp/Outside", prompt: "outside",
            messagesPath: outside.path
        )
        await #expect(throws: ClineReaderError.self) {
            _ = try await fixture.reader.load("outside")
        }

        let target = fixture.messagesURL(id: "linked-target")
        try fixture.writeJSON(["messages": []], to: target)
        let linkedDirectory = fixture.sessionsRoot.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
        let link = linkedDirectory.appendingPathComponent("linked.messages.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try fixture.insertSession(
            id: "linked", workspace: "/tmp/Linked", prompt: "linked", messagesPath: link.path
        )
        await #expect(throws: ClineReaderError.self) {
            _ = try await fixture.reader.load("linked")
        }

        let otherSession = fixture.messagesURL(id: "other-session")
        try fixture.writeJSON([
            "messages": [["role": "user", "content": "wrong session"]]
        ], to: otherSession)
        try fixture.insertSession(
            id: "cross-bound", workspace: "/tmp/CrossBound", prompt: "cross-bound",
            messagesPath: otherSession.path
        )
        await #expect(throws: ClineReaderError.self) {
            _ = try await fixture.reader.load("cross-bound")
        }
    }

    @Test("incremental discovery skips an unchanged database")
    func skipsKnownDatabase() async throws {
        let fixture = try ClineFixture()
        defer { fixture.remove() }
        try fixture.insertSession(id: "known", workspace: "/tmp/Known", prompt: "known")

        let sessions = try await fixture.reader.discover(knownFiles: [
            fixture.databaseURL.path: .distantFuture
        ])

        #expect(sessions.isEmpty)
    }
}

private final class ClineFixture {
    let root: URL
    let databaseURL: URL
    let sessionsRoot: URL
    var reader: ClineReader {
        ClineReader(databaseURL: databaseURL, sessionsRoot: sessionsRoot)
    }

    init(createDatabase: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeReentry-Cline-\(UUID().uuidString)", isDirectory: true)
        databaseURL = root.appendingPathComponent("db/sessions.db")
        sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        if createDatabase {
            try execute("""
            CREATE TABLE sessions (
                session_id TEXT PRIMARY KEY,
                started_at TEXT NOT NULL,
                updated_at TEXT NOT NULL,
                cwd TEXT NOT NULL,
                workspace_root TEXT NOT NULL,
                parent_session_id TEXT,
                is_subagent INTEGER NOT NULL DEFAULT 0,
                prompt TEXT,
                metadata_json TEXT,
                messages_path TEXT
            );
            """)
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func messagesURL(id: String) -> URL {
        sessionsRoot.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("\(id).messages.json")
    }

    func insertSession(
        id: String, workspace: String, prompt: String, metadata: String? = nil,
        messagesPath: String? = nil, parent: String? = nil, isSubagent: Bool = false
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        let sql = """
        INSERT INTO sessions (
            session_id, started_at, updated_at, cwd, workspace_root,
            parent_session_id, is_subagent, prompt, metadata_json, messages_path
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        let values: [String?] = [
            id, "2026-08-21T10:00:00.000Z", "2026-08-21T10:05:00.000Z",
            workspace + "/cwd", workspace, parent, isSubagent ? "1" : "0",
            prompt, metadata, messagesPath
        ]
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            if offset == 6 {
                sqlite3_bind_int(statement, Int32(offset + 1), isSubagent ? 1 : 0)
            } else if let value {
                _ = value.withCString {
                    sqlite3_bind_text(statement, Int32(offset + 1), $0, -1, transient)
                }
            } else {
                sqlite3_bind_null(statement, Int32(offset + 1))
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
    }

    func writeManifest(id: String, workspace: String, prompt: String, messagesPath: String) throws {
        let manifest: [String: Any] = [
            "version": 1, "session_id": id, "source": "cli", "pid": 1,
            "started_at": "2026-08-21T10:00:00.000Z", "status": "idle",
            "interactive": true, "provider": "cline", "model": "test",
            "cwd": workspace, "workspace_root": workspace,
            "enable_tools": true, "enable_spawn": true, "enable_teams": false,
            "prompt": prompt, "messages_path": messagesPath
        ]
        let url = sessionsRoot.appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent("\(id).json")
        try writeJSON(manifest, to: url)
    }

    func writeJSON(_ object: Any, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
        try data.write(to: url)
    }

    private func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw FixtureError.sqlite
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw FixtureError.sqlite
        }
    }
}

private enum FixtureError: Error { case sqlite }
