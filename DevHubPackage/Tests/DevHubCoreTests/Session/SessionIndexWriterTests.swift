import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("SessionIndexWriter")
struct SessionIndexWriterTests {

    @MainActor
    private func makeWriter() throws -> SessionIndexWriter {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        return SessionIndexWriter(modelContainer: container)
    }

    @Test("upsert inserts when absent")
    @MainActor
    func upsertInsert() async throws {
        let writer = try makeWriter()
        try await writer.upsert(
            tool: "codex", toolSessionId: "abc",
            sourcePath: "/a", projectCwd: "/p",
            startedAt: Date(), updatedAt: Date(), messageCount: 1, title: "t", preview: "p"
        )
        let all = await writer.all()
        #expect(all.count == 1)
        #expect(all.first?.identityKey == "codex:abc")
    }

    @Test("upsert updates when present (same identityKey)")
    @MainActor
    func upsertUpdate() async throws {
        let writer = try makeWriter()
        let base = Date()
        try await writer.upsert(tool: "codex", toolSessionId: "same",
                                 sourcePath: "/a", projectCwd: "/p",
                                 startedAt: base, updatedAt: base, messageCount: 1, title: nil, preview: "a")
        try await writer.upsert(tool: "codex", toolSessionId: "same",
                                 sourcePath: "/b", projectCwd: "/p",
                                 startedAt: base, updatedAt: base.addingTimeInterval(60),
                                 messageCount: 2, title: "new", preview: "b")
        let all = await writer.all()
        #expect(all.count == 1)
        #expect(all.first?.sourcePath == "/b")
        #expect(all.first?.title == "new")
    }

    @Test("concurrent upserts stay unique (dedupe via actor)")
    @MainActor
    func concurrentNoDupes() async throws {
        let writer = try makeWriter()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask {
                    try? await writer.upsert(tool: "codex", toolSessionId: "shared",
                                              sourcePath: "/\(i)", projectCwd: "/p",
                                              startedAt: Date(), updatedAt: Date(),
                                              messageCount: i, title: nil, preview: "p\(i)")
                }
            }
        }
        let all = await writer.all()
        #expect(all.count == 1)
    }

    @Test("batch upsert writes an incremental pass")
    @MainActor
    func batchUpsert() async throws {
        let writer = try makeWriter()
        let now = Date()
        let sessions = [
            DiscoveredSession(
                tool: "codex", toolSessionId: "batch-a", sourcePath: "/a",
                projectCwd: "/p", startedAt: now, updatedAt: now,
                messageCount: -1, title: "A", preview: "a"
            ),
            DiscoveredSession(
                tool: "claude-code", toolSessionId: "batch-b", sourcePath: "/b",
                projectCwd: "", startedAt: now, updatedAt: now,
                messageCount: 2, title: "B", preview: "b"
            ),
        ]
        try await writer.upsertBatch(sessions, projectStableIdsByIdentity: [:])
        let all = await writer.all()
        #expect(all.count == 2)
        #expect(all.first { $0.toolSessionId == "batch-a" }?.messageCount == -1)
    }

    @Test("batch assigns its project relationship")
    @MainActor
    func batchAssignsProject() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(stableId: "fresh-project", name: "Fresh", path: "/tmp/fresh")
        context.insert(project)
        try context.save()
        let writer = SessionIndexWriter(modelContainer: container)
        let session = DiscoveredSession(
            tool: "codex", toolSessionId: "fresh-session", sourcePath: "/tmp/fresh.jsonl",
            projectCwd: project.path, startedAt: Date(), updatedAt: Date(),
            messageCount: 1, title: "Fresh", preview: "Fresh"
        )

        try await writer.upsertBatch(
            [session],
            projectStableIdsByIdentity: [session.identityKey: project.stableId]
        )

        #expect(try await writer.fetchProjectStableId(identityKey: session.identityKey) == project.stableId)
    }

    @Test("fresh batch import persists every row across save boundaries")
    @MainActor
    func freshBatchPersistsAllRows() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(stableId: "batch-project", name: "Batch", path: "/tmp/batch")
        context.insert(project)
        try context.save()
        let writer = SessionIndexWriter(modelContainer: container)
        let now = Date()
        let sessions = (0..<5_001).map { index in
            DiscoveredSession(
                tool: "codex",
                toolSessionId: "batch-\(index)",
                sourcePath: "/tmp/batch.jsonl",
                projectCwd: project.path,
                startedAt: now,
                updatedAt: now,
                messageCount: 1,
                title: "Batch \(index)",
                preview: "Batch"
            )
        }
        let matches = Dictionary(uniqueKeysWithValues: sessions.map {
            ($0.identityKey, project.stableId)
        })

        try await writer.upsertBatch(sessions, projectStableIdsByIdentity: matches)

        let rows = await writer.all()
        #expect(rows.count == sessions.count)
        #expect(try await writer.fetchProjectStableId(
            identityKey: sessions.last!.identityKey
        ) == project.stableId)
    }

    @Test("bounded empty ZCode metadata is not reparsed forever")
    func boundedEmptyZcodeStopsReindexing() {
        #expect(SessionAggregator.shouldForceReindex(
            tool: "zcode", title: nil, preview: "", messageCount: 0
        ))
        #expect(!SessionAggregator.shouldForceReindex(
            tool: "zcode", title: nil, preview: "", messageCount: -1
        ))
        #expect(SessionAggregator.shouldForceReindex(
            tool: "codex",
            title: "<environment_context>old",
            preview: "<environment_context>old",
            messageCount: -1
        ))
    }

    @Test("removeStale drops entries whose sourcePath no longer exists")
    @MainActor
    func removeStale() async throws {
        let writer = try makeWriter()
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-session-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let liveSource = fixtureDirectory.appendingPathComponent("session_index.jsonl")
        try Data().write(to: liveSource)

        try await writer.upsert(tool: "codex", toolSessionId: "live",
                                 sourcePath: liveSource.path,
                                 projectCwd: "/p", startedAt: Date(), updatedAt: Date(),
                                 messageCount: 0, title: nil, preview: "")
        try await writer.upsert(tool: "codex", toolSessionId: "dead",
                                 sourcePath: "/nonexistent/dead.jsonl",
                                 projectCwd: "/p", startedAt: Date(), updatedAt: Date(),
                                 messageCount: 0, title: nil, preview: "")
        let removed = try await writer.removeStale()
        #expect(removed == 1)
        let all = await writer.all()
        #expect(all.count == 1)
        #expect(all.first?.toolSessionId == "live")
    }

    @Test("refresh preparation caches live sources and invalidates when a source disappears")
    @MainActor
    func refreshPreparationInvalidatesMissingSource() async throws {
        let writer = try makeWriter()
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-refresh-preparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let source = fixtureDirectory.appendingPathComponent("session.jsonl")
        try Data().write(to: source)

        try await writer.upsert(
            tool: "codex", toolSessionId: "cached", sourcePath: source.path,
            projectCwd: "/p", startedAt: Date(), updatedAt: Date(),
            messageCount: 1, title: "Cached", preview: "Cached"
        )
        let live = try await writer.prepareForRefresh()
        #expect(Set(live.keys) == Set([source.path]))

        try FileManager.default.removeItem(at: source)
        let afterRemoval = try await writer.prepareForRefresh()
        #expect(afterRemoval.isEmpty)
        #expect(await writer.all().isEmpty)
    }
}
