import Testing
import Foundation
@testable import DevHubCore

@Suite("MemoryStore")
struct MemoryStoreTests {

    @Test("ensure .devhub/memory/ exists and reads/writes context.md")
    func contextRoundtrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let store = MemoryStore(projectRoot: tmp)
        // 初始 context 为空字符串
        let initial = try store.readContext()
        #expect(initial == "")

        try store.writeContext("# ExampleApp\n项目记忆")
        let readBack = try store.readContext()
        #expect(readBack == "# ExampleApp\n项目记忆")

        // .devhub/memory/context.md 文件存在
        let ctxFile = tmp.appendingPathComponent(".devhub/memory/context.md")
        #expect(FileManager.default.fileExists(atPath: ctxFile.path))
    }

    @Test("summary read/write")
    func summaryRoundtrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = MemoryStore(projectRoot: tmp)

        try store.writeLastSessionSummary("上次改了登录")
        let read = try store.readLastSessionSummary()
        #expect(read == "上次改了登录")
    }

    @Test("summary metadata round-trip")
    func summaryMetadataRoundtrip() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = MemoryStore(projectRoot: tmp)
        let metadata = SessionSummaryMetadata(
            tool: "codex",
            toolSessionId: "session-123",
            sessionUpdatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        try store.writeLastSessionSummary("上次改了登录", metadata: metadata)

        #expect(try store.readLastSessionSummaryMetadata() == metadata)
    }

    @Test("rewriting summary without metadata removes stale provenance")
    func summaryWithoutMetadataRemovesStaleProvenance() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = MemoryStore(projectRoot: tmp)
        let metadata = SessionSummaryMetadata(
            tool: "codex",
            toolSessionId: "old-session",
            sessionUpdatedAt: Date()
        )
        try store.writeLastSessionSummary("旧总结", metadata: metadata)

        try store.writeLastSessionSummary("手工替换的总结")

        #expect(try store.readLastSessionSummaryMetadata() == nil)
    }

    @Test("summary review status distinguishes absent, current, outdated, and legacy files")
    func summaryReviewStatusClassification() {
        let sourceDate = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = SessionSummaryMetadata(
            tool: "claude-code",
            toolSessionId: "session-1",
            sessionUpdatedAt: sourceDate
        )

        #expect(SessionSummaryReviewStatus.classify(
            summary: nil, metadata: nil, latestIndexedSessionAt: nil
        ) == .none)
        #expect(SessionSummaryReviewStatus.classify(
            summary: "摘要", metadata: nil, latestIndexedSessionAt: sourceDate
        ) == .unverified)
        #expect(SessionSummaryReviewStatus.classify(
            summary: "摘要",
            metadata: SessionSummaryMetadata(
                schemaVersion: 99,
                tool: "codex",
                toolSessionId: "future",
                sessionUpdatedAt: sourceDate
            ),
            latestIndexedSessionAt: sourceDate
        ) == .unverified)
        #expect(SessionSummaryReviewStatus.classify(
            summary: "摘要", metadata: metadata, latestIndexedSessionAt: sourceDate
        ) == .current)
        #expect(SessionSummaryReviewStatus.classify(
            summary: "摘要",
            metadata: metadata,
            latestIndexedSessionAt: sourceDate.addingTimeInterval(1)
        ) == .outdated)
    }

    @Test("summary returns nil when absent")
    func summaryAbsent() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let store = MemoryStore(projectRoot: tmp)
        #expect(try store.readLastSessionSummary() == nil)
    }

    @Test("does NOT touch any file outside .devhub/")
    func noSourceModification() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mem-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        // 写一个源文件
        let sourceFile = tmp.appendingPathComponent("README.md")
        try "original".write(to: sourceFile, atomically: true, encoding: .utf8)

        let store = MemoryStore(projectRoot: tmp)
        try store.writeContext("# memory")

        // README.md 未被改动
        let content = try String(contentsOf: sourceFile)
        #expect(content == "original")
    }
}
