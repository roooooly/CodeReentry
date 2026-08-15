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
