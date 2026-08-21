import Foundation
import Testing
@testable import DevHubCore

@Suite("PiReader")
struct PiReaderTests {
    @Test("discovers direct and project-scoped sessions from headers only")
    func discoversMetadata() async throws {
        let fixture = try PiFixture()
        let nested = try fixture.write(
            name: "new.jsonl", directory: "--Projects-app--",
            lines: [Self.header(id: "new-session", cwd: "/Projects/app", timestamp: "2026-08-20T10:00:00.000Z")]
        )
        _ = try fixture.write(
            name: "old.jsonl",
            lines: [Self.header(id: "old-session", cwd: "/Projects/lib", timestamp: "2026-08-19T10:00:00.000Z")]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date.distantFuture], ofItemAtPath: nested.path
        )

        let sessions = try await fixture.reader.discover()

        #expect(sessions.count == 2)
        #expect(sessions[0].tool == "pi")
        #expect(sessions[0].toolSessionId == JSONLStreamReader.canonicalPath(nested.path))
        #expect(sessions[0].sourcePath == sessions[0].toolSessionId)
        #expect(sessions[0].projectCwd == "/Projects/app")
        #expect(sessions[0].title == "Pi new-session")
        #expect(sessions[0].messageCount == -1)
    }

    @Test("discovery is bounded and incremental")
    func boundedAndIncremental() async throws {
        let fixture = try PiFixture()
        for index in 0..<3 {
            _ = try fixture.write(
                name: "s\(index).jsonl",
                lines: [Self.header(id: "s\(index)", cwd: "/p", timestamp: "2026-01-01T00:00:00Z")]
            )
        }
        let reader = PiReader(sessionRoot: fixture.root, maxSessions: 2)
        let sessions = try await reader.discover()
        #expect(sessions.count == 2)
        let known = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sourcePath, Date.distantFuture) })
        #expect(try await reader.discover(knownFiles: known).count == 0)
    }

    @Test("loads only visible text on the active Pi branch")
    func loadsActiveConversation() async throws {
        let fixture = try PiFixture()
        let file = try fixture.write(name: "tree.jsonl", lines: [
            Self.header(id: "tree-session", cwd: "/Projects/app", timestamp: "2026-08-20T10:00:00.000Z"),
            Self.message(id: "u1", parent: nil, role: "user", content: #"[{"type":"text","text":"Fix checkout"},{"type":"image","data":"private"}]"#),
            Self.message(id: "a1", parent: "u1", role: "assistant", content: #"[{"type":"thinking","thinking":"private reasoning"},{"type":"text","text":"I found the redirect."},{"type":"toolCall","name":"bash"}]"#),
            Self.message(id: "old-u", parent: "a1", role: "user", content: #""abandoned branch""#),
            Self.message(id: "old-a", parent: "old-u", role: "assistant", content: #""abandoned answer""#),
            Self.message(id: "active-u", parent: "a1", role: "user", content: #""Apply the fix""#),
            Self.message(id: "active-a", parent: "active-u", role: "assistant", content: #"[{"type":"text","text":"The redirect is fixed."}]"#),
            #"{"type":"custom_message","id":"custom","parentId":"active-a","timestamp":"2026-08-20T10:06:00.000Z","customType":"fixture","content":"secret extension context","display":true}"#,
            Self.message(id: "tool", parent: "custom", role: "toolResult", content: #"[{"type":"text","text":"secret output"}]"#)
        ])

        let detail = try await fixture.reader.load(JSONLStreamReader.canonicalPath(file.path))

        #expect(detail.tool == "pi")
        #expect(detail.cwd == "/Projects/app")
        #expect(detail.toolSessionId == JSONLStreamReader.canonicalPath(file.path))
        #expect(detail.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(detail.messages.map(\.content) == [
            "Fix checkout", "I found the redirect.", "Apply the fix", "The redirect is fixed."
        ])
        #expect(detail.messages.allSatisfy {
            !$0.content.contains("private") && !$0.content.contains("abandoned") && !$0.content.contains("secret")
        })
        #expect(!detail.isTruncated)
    }

    @Test("detail keeps newest messages within message and character budgets")
    func boundedDetail() async throws {
        let fixture = try PiFixture()
        let file = try fixture.write(name: "bounded.jsonl", lines: [
            Self.header(id: "bounded", cwd: "/p", timestamp: "2026-01-01T00:00:00Z"),
            Self.message(id: "u1", parent: nil, role: "user", content: #""old""#),
            Self.message(id: "a1", parent: "u1", role: "assistant", content: #""abcdefghij""#)
        ])
        let detail = try await PiReader(
            sessionRoot: fixture.root, maxMessages: 1, maxCharacters: 5
        ).load(JSONLStreamReader.canonicalPath(file.path))
        #expect(detail.messages.map(\.content) == ["abcde"])
        #expect(detail.isTruncated)
    }

    @Test("absolute environment override selects the custom root")
    func standardRoot() {
        let home = URL(fileURLWithPath: "/tmp/test-home", isDirectory: true)
        #expect(PiReader.standardSessionRoot(homeURL: home, environment: [:]).path
            == "/tmp/test-home/.pi/agent/sessions")
        #expect(PiReader.standardSessionRoot(
            homeURL: home, environment: ["PI_CODING_AGENT_SESSION_DIR": "/tmp/pi-sessions"]
        ).path == "/tmp/pi-sessions")
        #expect(PiReader.standardSessionRoot(
            homeURL: home, environment: ["PI_CODING_AGENT_SESSION_DIR": "relative"]
        ).path == "/tmp/test-home/.pi/agent/sessions")
    }

    @Test("rejects arbitrary paths, oversized details, and symbolic roots")
    func rejectsUnsafeSources() async throws {
        let fixture = try PiFixture()
        let file = try fixture.write(name: "large.jsonl", lines: [
            Self.header(id: "large", cwd: "/p", timestamp: "2026-01-01T00:00:00Z"),
            Self.message(id: "u1", parent: nil, role: "user", content: #""payload""#)
        ])
        await #expect(throws: PiReaderError.sessionNotFound("/tmp/not-in-root.jsonl")) {
            _ = try await fixture.reader.load("/tmp/not-in-root.jsonl")
        }
        await #expect(throws: PiReaderError.self) {
            _ = try await PiReader(sessionRoot: fixture.root, maxDetailBytes: 10)
                .load(JSONLStreamReader.canonicalPath(file.path))
        }

        let link = fixture.root.deletingLastPathComponent()
            .appendingPathComponent("Pi-Link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        defer { try? FileManager.default.removeItem(at: link) }
        await #expect(throws: PiReaderError.self) {
            _ = try await PiReader(sessionRoot: link).discover()
        }
    }

    private static func header(id: String, cwd: String, timestamp: String) -> String {
        #"{"type":"session","version":3,"id":"\#(id)","timestamp":"\#(timestamp)","cwd":"\#(cwd)"}"#
    }

    private static func message(
        id: String, parent: String?, role: String, content: String
    ) -> String {
        let parentJSON = parent.map { #""\#($0)""# } ?? "null"
        return #"{"type":"message","id":"\#(id)","parentId":\#(parentJSON),"timestamp":"2026-08-20T10:01:00.000Z","message":{"role":"\#(role)","content":\#(content)}}"#
    }
}

private final class PiFixture {
    let root: URL
    var reader: PiReader { PiReader(sessionRoot: root) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeReentry-Pi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func write(name: String, directory: String? = nil, lines: [String]) throws -> URL {
        let destination: URL
        if let directory {
            destination = root.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        } else {
            destination = root
        }
        let file = destination.appendingPathComponent(name)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        return file
    }
}
