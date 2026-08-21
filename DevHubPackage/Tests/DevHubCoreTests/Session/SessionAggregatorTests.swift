import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("SessionAggregator")
struct SessionAggregatorTests {

    @MainActor
    @Test("aggregates multiple readers and writes to SessionIndexWriter")
    func aggregates() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let writer = SessionIndexWriter(modelContainer: container)
        let ctx = ModelContext(container)
        let project = Project(stableId: "s1", name: "sample-workspace", path: "/Users/example/Projects/sample-workspace")
        ctx.insert(project)
        try ctx.save()

        // 用两个 fixture reader
        let fixture1 = FixtureReader(sessions: [
            DiscoveredSession(tool: "claude-code", toolSessionId: "a",
                              sourcePath: "/tmp/a.jsonl", projectCwd: "/Users/example/Projects/sample-workspace",
                              startedAt: Date(), updatedAt: Date(), messageCount: 1, title: nil, preview: "x")
        ])
        let fixture2 = FixtureReader(sessions: [
            DiscoveredSession(tool: "codex", toolSessionId: "b",
                              sourcePath: "/tmp/b.jsonl", projectCwd: "/elsewhere",
                              startedAt: Date(), updatedAt: Date(), messageCount: 1, title: nil, preview: "y")
        ])

        let aggregator = SessionAggregator(readers: [fixture1, fixture2])
        try await aggregator.aggregate(writer: writer, modelContext: ctx)

        let all = await writer.all()
        #expect(all.count == 2)
        // sample-workspace project 应关联到 fixture1 的会话
        let claudeSession = all.first { $0.tool == "claude-code" }
        #expect(claudeSession != nil)
    }

    @Test("aggregator dedupes by identityKey")
    @MainActor
    func dedupes() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let writer = SessionIndexWriter(modelContainer: container)
        let ctx = ModelContext(container)
        let dupSession = DiscoveredSession(tool: "codex", toolSessionId: "same",
                                            sourcePath: "/a", projectCwd: "/p",
                                            startedAt: Date(), updatedAt: Date(), messageCount: 1, title: nil, preview: "a")
        let reader = FixtureReader(sessions: [dupSession, dupSession])
        let aggregator = SessionAggregator(readers: [reader])
        try await aggregator.aggregate(writer: writer, modelContext: ctx)
        let all = await writer.all()
        #expect(all.count == 1)  // dedupe by identityKey
    }

    @Test("a failed reader is reported after successful readers are written")
    @MainActor
    func readerFailureDoesNotBlockOthers() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let writer = SessionIndexWriter(modelContainer: container)
        let ctx = ModelContext(container)
        let successful = FixtureReader(sessions: [
            DiscoveredSession(
                tool: "codex", toolSessionId: "kept", sourcePath: "/tmp/kept.jsonl",
                projectCwd: "/tmp", startedAt: Date(), updatedAt: Date(),
                messageCount: 1, title: "Kept", preview: "Kept"
            )
        ])
        let aggregator = SessionAggregator(readers: [FailingReader(), successful])

        await #expect(throws: SessionAggregationError.self) {
            try await aggregator.aggregate(writer: writer, modelContext: ctx)
        }
        let all = await writer.all()
        #expect(all.map(\.toolSessionId) == ["kept"])
    }

    @Test("cwd 位于项目子目录时归入最具体的项目")
    func matchesNestedProjectPath() {
        let matched = SessionAggregator.projectStableId(
            for: "/Users/example/Projects/app/Sources/Feature",
            among: [
                (path: "/Users/example/Projects", stableId: "root"),
                (path: "/Users/example/Projects/app", stableId: "app"),
                (path: "/Users/example/Projects/other", stableId: "other"),
            ]
        )
        #expect(matched == "app")
    }

    @Test("相似路径前缀不能误归类")
    func pathBoundaryPreventsFalseMatch() {
        let matched = SessionAggregator.projectStableId(
            for: "/Users/example/Projects/application",
            among: [(path: "/Users/example/Projects/app", stableId: "app")]
        )
        #expect(matched == nil)
    }
}

struct FixtureReader: SessionReader {
    let toolId = "fixture"
    let sessions: [DiscoveredSession]
    func discover() async throws -> [DiscoveredSession] { sessions }
    func load(_ id: String) async throws -> SessionDetail {
        SessionDetail(tool: "fixture", toolSessionId: id, cwd: "/", startedAt: Date(), messages: [])
    }
}

struct FailingReader: SessionReader {
    let toolId = "broken"
    func discover() async throws -> [DiscoveredSession] { throw FixtureReaderError.invalid }
    func load(_ id: String) async throws -> SessionDetail { throw FixtureReaderError.invalid }
}

enum FixtureReaderError: Error {
    case invalid
}
