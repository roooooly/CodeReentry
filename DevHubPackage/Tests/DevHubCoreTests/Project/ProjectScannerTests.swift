import Testing
import Foundation
@testable import DevHubCore

@Suite("ProjectScanner")
struct ProjectScannerTests {

    private func makeTempTree() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        // project A: git repo
        let a = tmp.appendingPathComponent("projA", isDirectory: true)
        try FileManager.default.createDirectory(at: a.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: a.appendingPathComponent("package.json"))

        // project B: rust
        let b = tmp.appendingPathComponent("projB", isDirectory: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try Data("[package]\nname=\"b\"".utf8).write(to: b.appendingPathComponent("Cargo.toml"))

        // not a project (no signal)
        let c = tmp.appendingPathComponent("just-files", isDirectory: true)
        try FileManager.default.createDirectory(at: c, withIntermediateDirectories: true)
        try Data("hi".utf8).write(to: c.appendingPathComponent("readme.txt"))

        // project D: xcodeproj
        let d = tmp.appendingPathComponent("projD", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)

        return tmp
    }

    @Test("scans only dirs containing a signal file")
    func scansCandidates() throws {
        let root = try makeTempTree()
        let scanner = ProjectScanner(rootURL: root, maxDepth: 2)
        let candidates = try scanner.scan()
        let names = Set(candidates.map { $0.url.lastPathComponent })
        #expect(names == ["projA", "projB", "projD"])
    }

    @Test("candidate signals include detected markers")
    func candidateSignals() throws {
        let root = try makeTempTree()
        let scanner = ProjectScanner(rootURL: root, maxDepth: 2)
        let candidates = try scanner.scan()
        let a = candidates.first { $0.url.lastPathComponent == "projA" }!
        #expect(a.signals.contains(.git))
        #expect(a.signals.contains(.packageJson))
    }

    @Test("depth limit prevents deep recursion")
    func depthLimit() throws {
        let root = try makeTempTree()
        let deepDir = root.appendingPathComponent("d1/d2/d3/d4", isDirectory: true)
        try FileManager.default.createDirectory(at: deepDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: deepDir.appendingPathComponent("package.json"))

        let shallow = try ProjectScanner(rootURL: root, maxDepth: 2).scan()
        #expect(!shallow.contains { $0.url.lastPathComponent == "d4" })

        let deep = try ProjectScanner(rootURL: root, maxDepth: 10).scan()
        #expect(deep.contains { $0.url.lastPathComponent == "d4" })
    }
}
