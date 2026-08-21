import Foundation
import Testing
@testable import DevHubCore

@Suite("AiderReader")
struct AiderReaderTests {
    @Test("discovers the exact registered project history and uses the newest request")
    func discoversProjectHistory() async throws {
        let fixture = try Fixture(history: """
        # aider chat started at 2026-08-20 09:15:00

        #### Add project search

        I added the first pass.

        > Tokens: 1k sent, 200 received.

        # aider chat started at 2026-08-21 10:30:00

        #### Tighten the path boundary

        The scanner now stays inside the registered root.
        """)
        defer { fixture.remove() }

        let sessions = try await AiderReader(projectRoots: [fixture.root]).discover()
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.tool == "aider")
        #expect(session.toolSessionId == fixture.root.path)
        #expect(session.sourcePath == fixture.historyURL.path)
        #expect(session.projectCwd == fixture.root.path)
        #expect(session.messageCount == 4)
        #expect(session.title == "Tighten the path boundary")
        #expect(session.preview == "Tighten the path boundary")
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: session.startedAt
        )
        #expect(components.year == 2026)
        #expect(components.month == 8)
        #expect(components.day == 21)
        #expect(components.hour == 10)
        #expect(components.minute == 30)
    }

    @Test("loads only user and assistant conversation while preserving Markdown spacing")
    func loadsConversation() async throws {
        let fixture = try Fixture(history: """
        # aider chat started at 2026-08-20 09:15:00

        #### Explain the result

        First paragraph.

        ```swift
        let value = 1
        ```

        > Applied edit to Example.swift

        #### Verify it

        All focused tests pass.
        """)
        defer { fixture.remove() }

        let detail = try await AiderReader(projectRoots: [fixture.root]).load(fixture.root.path)
        #expect(detail.cwd == fixture.root.path)
        #expect(detail.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(detail.messages[0].content == "Explain the result")
        #expect(detail.messages[1].content.contains("First paragraph.\n\n```swift"))
        #expect(!detail.messages.map(\.content).joined().contains("Applied edit"))
        #expect(detail.isTruncated == false)
    }

    @Test("incremental discovery skips an unchanged indexed history")
    func skipsKnownHistory() async throws {
        let fixture = try Fixture(history: "#### Existing request\n\nExisting response.\n")
        defer { fixture.remove() }
        let modifiedAt = try #require(
            try fixture.historyURL.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
        )

        let sessions = try await AiderReader(projectRoots: [fixture.root]).discover(
            knownFiles: [fixture.historyURL.path: modifiedAt]
        )
        #expect(sessions.isEmpty)
    }

    @Test("rejects a symbolic-link history instead of following it")
    func rejectsSymlink() async throws {
        let fixture = try Fixture(history: nil)
        defer { fixture.remove() }
        let outside = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        try "#### Private request\n\nPrivate response.\n".write(
            to: outside, atomically: true, encoding: .utf8
        )
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: fixture.historyURL,
            withDestinationURL: outside
        )

        let sessions = try await AiderReader(projectRoots: [fixture.root]).discover()
        #expect(sessions.isEmpty)
    }

    @Test("preserves a registered symbolic-link project identity")
    func preservesRegisteredRootAlias() async throws {
        let fixture = try Fixture(history: "#### Alias request\n\nAlias response.\n")
        defer { fixture.remove() }
        let alias = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("aider-alias-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        defer { try? FileManager.default.removeItem(at: alias) }

        let session = try #require(
            try await AiderReader(projectRoots: [alias]).discover().first
        )
        #expect(session.toolSessionId == alias.path)
        #expect(session.projectCwd == alias.path)
    }

    @Test("keeps newest messages when the detail budget is reached")
    func keepsNewestMessages() async throws {
        let fixture = try Fixture(history: """
        #### First

        First response.

        #### Second

        Second response.

        #### Third

        Third response.
        """)
        defer { fixture.remove() }

        let detail = try await AiderReader(
            projectRoots: [fixture.root],
            maxDetailMessages: 2
        ).load(fixture.root.path)
        #expect(detail.messages.map(\.content) == ["Third", "Third response."])
        #expect(detail.isTruncated)
    }

    @Test("bounded tail discovery and detail keep the newest project context")
    func keepsNewestTailContext() async throws {
        let oldResponse = String(repeating: "old-context ", count: 80)
        let fixture = try Fixture(history: """
        #### Old request

        \(oldResponse)

        #### Latest request

        Latest response.
        """)
        defer { fixture.remove() }
        let reader = AiderReader(
            projectRoots: [fixture.root],
            metadataTailBytes: 96,
            detailTailBytes: 96
        )

        let session = try #require(try await reader.discover().first)
        #expect(session.preview == "Latest request")
        #expect(session.messageCount == -1)
        let detail = try await reader.load(fixture.root.path)
        #expect(detail.messages.map(\.content) == ["Latest request", "Latest response."])
        #expect(detail.isTruncated)
    }

    @Test("reports a missing project history identity")
    func missingHistory() async throws {
        let fixture = try Fixture(history: "#### Request\n\nResponse.\n")
        defer { fixture.remove() }

        await #expect(throws: AiderReaderError.sessionNotFound("missing")) {
            _ = try await AiderReader(projectRoots: [fixture.root]).load("missing")
        }
    }

    private struct Fixture {
        let root: URL
        let historyURL: URL

        init(history: String?) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("codereentry-aider-\(UUID().uuidString)", isDirectory: true)
            historyURL = root.appendingPathComponent(".aider.chat.history.md")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if let history {
                try history.write(to: historyURL, atomically: true, encoding: .utf8)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
