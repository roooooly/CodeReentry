import Foundation
import Testing
@testable import DevHubCore

@Suite("GeminiReader")
struct GeminiReaderTests {
    @Test("discovers a main session from the ownership marker")
    func discoversSession() async throws {
        let fixture = try GeminiFixture(markerProjectRoot: "/Projects/checkout")
        let file = try fixture.writeSession(lines: [
            Self.metadata(id: "a1b2c3d4-e5f6-7890-abcd-ef1234567890"),
            Self.message(id: "u1", type: "user", content: [["text": "Fix checkout flow"]]),
            Self.message(id: "g1", type: "gemini", content: "I will inspect it.")
        ])
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        let sessions = try await GeminiReader(geminiRoot: fixture.geminiRoot).discover()

        #expect(sessions.count == 1)
        #expect(sessions[0].tool == "gemini-cli")
        #expect(sessions[0].toolSessionId == "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
        #expect(sessions[0].projectCwd == "/Projects/checkout")
        #expect(sessions[0].title == "Fix checkout flow")
        #expect(sessions[0].preview == "Fix checkout flow")
        #expect(sessions[0].messageCount == 2)
        #expect(sessions[0].updatedAt == modified)
        #expect(sessions[0].sourcePath == JSONLStreamReader.canonicalPath(file.path))
    }

    @Test("projects.json resolves the project when the marker is absent")
    func registryFallback() async throws {
        let fixture = try GeminiFixture(
            markerProjectRoot: nil,
            registryProjectRoot: "/Projects/from-registry"
        )
        _ = try fixture.writeSession(lines: [
            Self.metadata(id: "registry-session"),
            Self.message(id: "u1", type: "user", content: "Continue registry project")
        ])

        let session = try #require(
            try await GeminiReader(geminiRoot: fixture.geminiRoot).discover().first
        )

        #expect(session.projectCwd == "/Projects/from-registry")
    }

    @Test("ownership marker wins over a stale registry entry")
    func markerWins() async throws {
        let fixture = try GeminiFixture(
            markerProjectRoot: "/Projects/current",
            registryProjectRoot: "/Projects/stale"
        )
        _ = try fixture.writeSession(lines: [
            Self.metadata(id: "marker-session"),
            Self.message(id: "u1", type: "user", content: "Use current root")
        ])

        let session = try #require(
            try await GeminiReader(geminiRoot: fixture.geminiRoot).discover().first
        )

        #expect(session.projectCwd == "/Projects/current")
    }

    @Test("discovery is globally bounded and incremental")
    func boundedAndIncremental() async throws {
        let fixture = try GeminiFixture(markerProjectRoot: "/Projects/app")
        let older = try fixture.writeSession(name: "session-older.jsonl", lines: [
            Self.metadata(id: "older"),
            Self.message(id: "u1", type: "user", content: "Older")
        ])
        let newer = try fixture.writeSession(name: "session-newer.jsonl", lines: [
            Self.metadata(id: "newer"),
            Self.message(id: "u2", type: "user", content: "Newer")
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path
        )
        let reader = GeminiReader(geminiRoot: fixture.geminiRoot, maxSessionFiles: 1)

        let first = try await reader.discover()
        #expect(first.map(\.toolSessionId) == ["newer"])

        let unchanged = try await reader.discover(knownFiles: [newer.path: .distantFuture])
        #expect(unchanged.isEmpty)
    }

    @Test("subagent sessions are not surfaced as independent resumable work")
    func skipsSubagents() async throws {
        let fixture = try GeminiFixture(markerProjectRoot: "/Projects/app")
        _ = try fixture.writeSession(lines: [
            Self.metadata(id: "subagent", kind: "subagent"),
            Self.message(id: "u1", type: "user", content: "Internal task")
        ])

        let sessions = try await GeminiReader(geminiRoot: fixture.geminiRoot).discover()

        #expect(sessions.isEmpty)
    }

    @Test("detail loading applies rewind records and exposes bounded tool calls")
    func loadsDetailWithRewind() async throws {
        let fixture = try GeminiFixture(markerProjectRoot: "/Projects/app")
        _ = try fixture.writeSession(lines: [
            Self.metadata(id: "detail-session"),
            Self.message(id: "u1", type: "user", content: "Inspect the project"),
            Self.message(id: "g1", type: "gemini", content: "I found the issue."),
            Self.message(id: "u2", type: "user", content: "Discard this branch"),
            ["$rewindTo": "u2"],
            Self.message(id: "u3", type: "user", content: "Use the safer fix"),
            Self.message(
                id: "g2",
                type: "gemini",
                content: NSNull(),
                toolCalls: [[
                    "id": "call-1",
                    "name": "replace",
                    "args": ["path": "Sources/App.swift"],
                    "timestamp": "2026-08-21T01:04:00.000Z"
                ]]
            )
        ])

        let detail = try await GeminiReader(geminiRoot: fixture.geminiRoot).load("detail-session")

        #expect(detail.cwd == "/Projects/app")
        #expect(detail.messages.map(\.role) == [.user, .assistant, .user, .tool])
        #expect(detail.messages.map(\.content).contains("Discard this branch") == false)
        #expect(detail.messages.last?.toolName == "replace")
        #expect(detail.messages.last?.toolInput?.contains("Sources/App.swift") == true)
        #expect(detail.isTruncated == false)
    }

    @Test("metadata count follows rewind and checkpoint records")
    func metadataCountFollowsUpdates() async throws {
        let fixture = try GeminiFixture(markerProjectRoot: "/Projects/app")
        _ = try fixture.writeSession(lines: [
            Self.metadata(id: "updated-session"),
            Self.message(id: "u1", type: "user", content: "Original prompt"),
            Self.message(id: "g1", type: "gemini", content: "Original answer"),
            Self.message(id: "u2", type: "user", content: "Remove from here"),
            ["$rewindTo": "u2"],
            ["$set": ["messages": [
                Self.message(id: "u1", type: "user", content: "Original prompt"),
                Self.message(id: "g1", type: "gemini", content: "Original answer"),
                Self.message(id: "u3", type: "user", content: "Replacement prompt")
            ]]]
        ])

        let session = try #require(
            try await GeminiReader(geminiRoot: fixture.geminiRoot).discover().first
        )

        #expect(session.messageCount == 3)
        #expect(session.title == "Original prompt")
    }

    @Test("checkpoint-only history still exposes its first user prompt")
    func checkpointProvidesPreview() async throws {
        let fixture = try GeminiFixture(markerProjectRoot: "/Projects/app")
        _ = try fixture.writeSession(lines: [
            Self.metadata(id: "checkpoint-session"),
            ["$set": ["messages": [
                Self.message(id: "u1", type: "user", content: "Recovered checkpoint"),
                Self.message(id: "g1", type: "gemini", content: "Recovered answer")
            ]]]
        ])

        let session = try #require(
            try await GeminiReader(geminiRoot: fixture.geminiRoot).discover().first
        )

        #expect(session.title == "Recovered checkpoint")
        #expect(session.preview == "Recovered checkpoint")
        #expect(session.messageCount == 2)
    }

    @Test("oversized inline data is skipped without defeating metadata discovery")
    func oversizedLineIsSkipped() async throws {
        let fixture = try GeminiFixture(markerProjectRoot: "/Projects/app")
        let oversized = String(repeating: "A", count: 1_100_000)
        _ = try fixture.writeSession(lines: [
            Self.metadata(id: "large-session"),
            Self.message(id: "g-large", type: "gemini", content: oversized),
            Self.message(id: "u1", type: "user", content: "Useful prompt after inline data")
        ])

        let session = try #require(
            try await GeminiReader(geminiRoot: fixture.geminiRoot).discover().first
        )

        #expect(session.toolSessionId == "large-session")
        #expect(session.title == "Useful prompt after inline data")
        #expect(session.messageCount == -1)
    }

    @Test("missing session fails explicitly")
    func missingSession() async throws {
        let fixture = try GeminiFixture(markerProjectRoot: "/Projects/app")

        await #expect(throws: GeminiReaderError.sessionNotFound("missing")) {
            _ = try await GeminiReader(geminiRoot: fixture.geminiRoot).load("missing")
        }
    }

    private static func metadata(id: String, kind: String = "main") -> [String: Any] {
        [
            "sessionId": id,
            "projectHash": "synthetic-project-hash",
            "startTime": "2026-08-21T01:00:00.000Z",
            "lastUpdated": "2026-08-21T01:05:00.000Z",
            "kind": kind
        ]
    }

    private static func message(
        id: String,
        type: String,
        content: Any,
        toolCalls: [[String: Any]]? = nil
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "type": type,
            "timestamp": "2026-08-21T01:01:00.000Z",
            "content": content
        ]
        if let toolCalls { value["toolCalls"] = toolCalls }
        return value
    }
}

private final class GeminiFixture {
    let directory: URL
    let geminiRoot: URL
    let chatsDirectory: URL

    init(markerProjectRoot: String?, registryProjectRoot: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeReentry-Gemini-\(UUID().uuidString)", isDirectory: true)
        geminiRoot = directory.appendingPathComponent(".gemini", isDirectory: true)
        let projectDirectory = geminiRoot
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("synthetic-project", isDirectory: true)
        chatsDirectory = projectDirectory.appendingPathComponent("chats", isDirectory: true)
        try FileManager.default.createDirectory(at: chatsDirectory, withIntermediateDirectories: true)

        if let markerProjectRoot {
            try markerProjectRoot.write(
                to: projectDirectory.appendingPathComponent(".project_root"),
                atomically: true,
                encoding: .utf8
            )
        }
        if let registryProjectRoot {
            let registry: [String: Any] = [
                "projects": [registryProjectRoot: "synthetic-project"]
            ]
            let data = try JSONSerialization.data(withJSONObject: registry, options: [.sortedKeys])
            try data.write(to: geminiRoot.appendingPathComponent("projects.json"))
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func writeSession(
        name: String = "session-2026-08-21T01-00-synthetic.jsonl",
        lines: [[String: Any]]
    ) throws -> URL {
        let data = try lines.reduce(into: Data()) { result, object in
            result.append(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            result.append(0x0A)
        }
        let file = chatsDirectory.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }
}
