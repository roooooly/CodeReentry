import Foundation
import Testing
@testable import DevHubCore

@Suite("JSONLStreamReader")
struct JSONLStreamReaderTests {
    private func write(_ value: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-jsonl-stream-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("fixture.jsonl")
        try value.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test("分块读取跨 chunk 的完整行")
    func readsAcrossChunks() throws {
        let file = try write("one\nsecond line\nthree")
        var lines: [String] = []
        let result = try JSONLStreamReader.forEachLine(
            at: file,
            chunkSize: 5,
            maximumLineBytes: 64
        ) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }
        #expect(lines == ["one", "second line", "three"])
        #expect(result.reachedEndOfFile)
    }

    @Test("尾部扫描丢弃起始位置的半行")
    func tailScanDropsPartialFirstLine() throws {
        let file = try write("partial line\nkept\n")
        var lines: [String] = []
        _ = try JSONLStreamReader.forEachLine(
            at: file,
            startingAtOffset: 3,
            chunkSize: 4
        ) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }
        #expect(lines == ["kept"])
    }

    @Test("超大单行被跳过且不阻断后续行")
    func skipsOversizedLine() throws {
        let file = try write("123456789\nok\n")
        var lines: [String] = []
        let result = try JSONLStreamReader.forEachLine(
            at: file,
            chunkSize: 4,
            maximumLineBytes: 5
        ) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }
        #expect(lines == ["ok"])
        #expect(result.skippedOversizedLines == 1)
    }

    @Test("有界头部扫描不把末尾半行当成完整 JSONL")
    func boundedHeadDoesNotYieldTrailingPartialLine() throws {
        let file = try write("first\nsecond\n")
        var lines: [String] = []

        let result = try JSONLStreamReader.forEachLine(at: file, byteLimit: 8) { data in
            lines.append(String(decoding: data, as: UTF8.self))
            return true
        }

        #expect(lines == ["first"])
        #expect(!result.reachedEndOfFile)
    }
}
