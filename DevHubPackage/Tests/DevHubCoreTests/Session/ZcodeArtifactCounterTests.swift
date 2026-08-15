import Foundation
import Testing
@testable import DevHubCore

@Suite("ZCode artifact counter")
struct ZcodeArtifactCounterTests {
    @Test("只统计会话 artifacts 下的普通文件并包含子目录")
    func countsFilesRecursively() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-zcode-artifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("rollout", isDirectory: true)
        let artifacts = root.appendingPathComponent("artifacts/sess_123/nested", isDirectory: true)
        try FileManager.default.createDirectory(at: rollout, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let source = rollout.appendingPathComponent("model-io-sess_123.jsonl")
        try Data().write(to: source)
        try Data("a".utf8).write(to: artifacts.deletingLastPathComponent().appendingPathComponent("one.txt"))
        try Data("b".utf8).write(to: artifacts.appendingPathComponent("two.png"))

        #expect(ZcodeArtifactCounter.count(sourcePath: source.path, sessionId: "sess_123") == 2)
        #expect(ZcodeArtifactCounter.count(sourcePath: source.path, sessionId: "sess_missing") == 0)
    }
}
