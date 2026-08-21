import Foundation
import Testing
@testable import DevHubCore

@Suite("GitHubCopilotReader")
struct GitHubCopilotReaderTests {
    @Test("discovers a session from documented persisted events")
    func discoversSession() async throws {
        let fixture = try CopilotFixture()
        let file = try fixture.writeSession(id: "session-1", events: [
            Self.context(cwd: "/Projects/checkout", gitRoot: "/Projects/checkout"),
            Self.event(type: "user.message", data: ["content": "Fix checkout flow"]),
            Self.event(type: "assistant.message", data: ["content": "I will inspect it."])
        ])
        let modified = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        let sessions = try await GitHubCopilotReader(copilotRoot: fixture.copilotRoot).discover()

        #expect(sessions.count == 1)
        #expect(sessions[0].tool == "github-copilot")
        #expect(sessions[0].toolSessionId == "session-1")
        #expect(sessions[0].projectCwd == "/Projects/checkout")
        #expect(sessions[0].title == "Fix checkout flow")
        #expect(sessions[0].preview == "Fix checkout flow")
        #expect(sessions[0].messageCount == 2)
        #expect(sessions[0].updatedAt == modified)
        #expect(sessions[0].sourcePath == JSONLStreamReader.canonicalPath(file.path))
    }

    @Test("git root is preferred and the latest context is used")
    func contextUpdates() async throws {
        let fixture = try CopilotFixture()
        _ = try fixture.writeSession(id: "session-context", events: [
            Self.context(cwd: "/Projects/old/subdirectory", gitRoot: "/Projects/old"),
            Self.event(type: "user.message", data: ["content": "Move the work"]),
            Self.context(cwd: "/Projects/new/Sources", gitRoot: "/Projects/new")
        ])

        let session = try #require(
            try await GitHubCopilotReader(copilotRoot: fixture.copilotRoot).discover().first
        )

        #expect(session.projectCwd == "/Projects/new")
    }

    @Test("sessions without a documented absolute project context are skipped")
    func skipsMissingContext() async throws {
        let fixture = try CopilotFixture()
        _ = try fixture.writeSession(id: "missing-context", events: [
            Self.event(type: "user.message", data: ["content": "No project here"])
        ])
        _ = try fixture.writeSession(id: "relative-context", events: [
            Self.context(cwd: "relative/path"),
            Self.event(type: "user.message", data: ["content": "Still not a project"])
        ])

        let sessions = try await GitHubCopilotReader(copilotRoot: fixture.copilotRoot).discover()

        #expect(sessions.isEmpty)
    }

    @Test("detail excludes reasoning, system prompts, and subagent events")
    func loadsPrivacyBoundedDetail() async throws {
        let fixture = try CopilotFixture()
        _ = try fixture.writeSession(id: "detail-session", events: [
            Self.context(cwd: "/Projects/app"),
            Self.event(type: "system.message", data: ["content": "private system prompt"]),
            Self.event(type: "user.message", data: ["content": "Inspect the project"]),
            Self.event(type: "assistant.reasoning", data: [
                "reasoningId": "r1", "content": "hidden reasoning"
            ]),
            Self.event(type: "assistant.message", data: [
                "content": "I found the issue.",
                "toolRequests": [[
                    "toolCallId": "call-1",
                    "name": "edit",
                    "arguments": ["path": "Sources/App.swift"]
                ]]
            ]),
            Self.event(
                type: "assistant.message",
                data: ["content": "subagent-only response"],
                agentId: "agent-1"
            )
        ])

        let detail = try await GitHubCopilotReader(
            copilotRoot: fixture.copilotRoot
        ).load("detail-session")

        #expect(detail.cwd == "/Projects/app")
        #expect(detail.messages.map(\.role) == [.user, .assistant, .tool])
        #expect(detail.messages.map(\.content).contains("private system prompt") == false)
        #expect(detail.messages.map(\.content).contains("hidden reasoning") == false)
        #expect(detail.messages.map(\.content).contains("subagent-only response") == false)
        #expect(detail.messages.last?.toolName == "edit")
        #expect(detail.messages.last?.toolInput?.contains("Sources/App.swift") == true)
        #expect(detail.isTruncated == false)
    }

    @Test("discovery is recent-first, globally bounded, and incremental")
    func boundedAndIncremental() async throws {
        let fixture = try CopilotFixture()
        let older = try fixture.writeSession(id: "older", events: [
            Self.context(cwd: "/Projects/older"),
            Self.event(type: "user.message", data: ["content": "Older"])
        ])
        let newer = try fixture.writeSession(id: "newer", events: [
            Self.context(cwd: "/Projects/newer"),
            Self.event(type: "user.message", data: ["content": "Newer"])
        ])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)],
            ofItemAtPath: older.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 200)],
            ofItemAtPath: newer.path
        )
        let reader = GitHubCopilotReader(
            copilotRoot: fixture.copilotRoot,
            maxSessionDirectories: 1
        )

        let first = try await reader.discover()
        #expect(first.map(\.toolSessionId) == ["newer"])

        let unchanged = try await reader.discover(knownFiles: [newer.path: .distantFuture])
        #expect(unchanged.isEmpty)
    }

    @Test("oversized event lines are skipped and reported as an unknown count")
    func skipsOversizedLine() async throws {
        let fixture = try CopilotFixture()
        _ = try fixture.writeSession(id: "large-session", events: [
            Self.context(cwd: "/Projects/app"),
            Self.event(type: "assistant.message", data: [
                "content": String(repeating: "A", count: 1_100_000)
            ]),
            Self.event(type: "user.message", data: ["content": "Useful prompt"])
        ])

        let session = try #require(
            try await GitHubCopilotReader(copilotRoot: fixture.copilotRoot).discover().first
        )

        #expect(session.title == "Useful prompt")
        #expect(session.messageCount == -1)
    }

    @Test("symbolic-linked event logs are not followed")
    func skipsSymbolicLinks() async throws {
        let fixture = try CopilotFixture()
        let target = try fixture.writeSession(id: "real", events: [
            Self.context(cwd: "/Projects/real"),
            Self.event(type: "user.message", data: ["content": "Real session"])
        ])
        let linkedDirectory = fixture.sessionState
            .appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createDirectory(
            at: linkedDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory.appendingPathComponent("events.jsonl"),
            withDestinationURL: target
        )

        let sessions = try await GitHubCopilotReader(copilotRoot: fixture.copilotRoot).discover()

        #expect(sessions.map(\.toolSessionId) == ["real"])
    }

    @Test("missing session fails explicitly")
    func missingSession() async throws {
        let fixture = try CopilotFixture()

        await #expect(throws: GitHubCopilotReaderError.sessionNotFound("missing")) {
            _ = try await GitHubCopilotReader(copilotRoot: fixture.copilotRoot).load("missing")
        }
    }

    private static func context(cwd: String, gitRoot: String? = nil) -> [String: Any] {
        var data: [String: Any] = ["cwd": cwd]
        if let gitRoot { data["gitRoot"] = gitRoot }
        return event(type: "session.context_changed", data: data)
    }

    private static func event(
        type: String,
        data: [String: Any],
        agentId: String? = nil
    ) -> [String: Any] {
        var event: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "timestamp": "2026-08-21T01:00:00.000Z",
            "parentId": NSNull(),
            "type": type,
            "data": data
        ]
        if let agentId { event["agentId"] = agentId }
        return event
    }
}

private final class CopilotFixture {
    let directory: URL
    let copilotRoot: URL
    let sessionState: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "CodeReentry-Copilot-\(UUID().uuidString)",
            isDirectory: true
        )
        copilotRoot = directory.appendingPathComponent(".copilot", isDirectory: true)
        sessionState = copilotRoot.appendingPathComponent("session-state", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionState,
            withIntermediateDirectories: true
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func writeSession(id: String, events: [[String: Any]]) throws -> URL {
        let session = sessionState.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let data = try events.map { event -> String in
            let encoded = try JSONSerialization.data(
                withJSONObject: event,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
            return try #require(String(data: encoded, encoding: .utf8))
        }.joined(separator: "\n") + "\n"
        let file = session.appendingPathComponent("events.jsonl")
        try data.write(to: file, atomically: true, encoding: .utf8)
        return file
    }
}
