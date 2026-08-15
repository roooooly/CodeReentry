import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("CodexArchiveReconciler")
struct CodexArchiveReconcilerTests {

    @MainActor
    private func makeSetup() throws -> (SessionIndexWriter, URL, URL) {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let writer = SessionIndexWriter(modelContainer: container)
        // 临时 codex root
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("codex-recon-\(UUID().uuidString)")
        let archDir = tmp.appendingPathComponent("archived_sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: archDir, withIntermediateDirectories: true)
        return (writer, tmp, archDir)
    }

    @Test("reconcile moves stale sourcePath to archived location when found there")
    @MainActor
    func reconcileMovesToArchived() async throws {
        let (writer, tmp, archDir) = try makeSetup()
        let sid = "deadbeef-0000-0000-0000-000000000001"
        // 在 archived_sessions 写一个 rollout
        let archFile = archDir.appendingPathComponent("rollout-x-\(sid).jsonl")
        try #"{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"cwd":"/p"}}"#.data(using: .utf8)!.write(to: archFile)
        // SessionIndex 里 sourcePath 指向 active 位置（不存在）
        try await writer.upsert(tool: "codex", toolSessionId: sid,
                                 sourcePath: tmp.appendingPathComponent("sessions/2026/01/01/rollout-x-\(sid).jsonl").path,
                                 projectCwd: "/p", startedAt: Date(), updatedAt: Date(),
                                 messageCount: 0, title: nil, preview: "")

        let reconciler = CodexArchiveReconciler(codexRoot: tmp)
        let count = try await reconciler.reconcile(writer: writer)
        #expect(count >= 1)
        let all = await writer.all()
        #expect(all.first?.sourcePath == archFile.path)
    }

    @Test("reconcile leaves valid sourcePath alone")
    @MainActor
    func leavesValidAlone() async throws {
        let (writer, tmp, _) = try makeSetup()
        let liveFile = tmp.appendingPathComponent("live.jsonl")
        try "data".data(using: .utf8)!.write(to: liveFile)
        try await writer.upsert(tool: "codex", toolSessionId: "live-1",
                                 sourcePath: liveFile.path, projectCwd: "/p",
                                 startedAt: Date(), updatedAt: Date(),
                                 messageCount: 0, title: nil, preview: "")
        let reconciler = CodexArchiveReconciler(codexRoot: tmp)
        let count = try await reconciler.reconcile(writer: writer)
        #expect(count == 0)
        let all = await writer.all()
        #expect(all.first?.sourcePath == liveFile.path)
    }
}
