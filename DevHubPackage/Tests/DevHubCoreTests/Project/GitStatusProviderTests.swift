import Testing
import Foundation
@testable import DevHubCore

@Suite("GitStatusProvider")
struct GitStatusProviderTests {

    private func makeGitRepo() throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        func run(_ args: [String]) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            p.currentDirectoryURL = tmp
            p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
            p.standardError = FileHandle(forWritingAtPath: "/dev/null")
            try p.run(); p.waitUntilExit()
        }
        try run(["init", "-b", "main"])
        try run(["config", "user.email", "t@t.com"])
        try run(["config", "user.name", "t"])
        try Data("hi".utf8).write(to: tmp.appendingPathComponent("a.txt"))
        try run(["add", "."])
        try run(["commit", "-m", "first"])
        // 制造一个未提交修改
        try Data("change".utf8).write(to: tmp.appendingPathComponent("a.txt"))
        try run(["add", "."])
        return tmp
    }

    @Test("parses branch + commit + dirty count")
    func parseGitStatus() async throws {
        let repo = try makeGitRepo()
        let provider = GitStatusProvider()
        let status = try await provider.status(at: repo)
        #expect(status?.branch == "main")
        #expect(status?.lastCommitSubject == "first")
        #expect(status?.dirtyFileCount == 1)
    }

    @Test("non-git dir returns nil status")
    func nonGit() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nogit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let provider = GitStatusProvider()
        let status = try await provider.status(at: tmp)
        #expect(status == nil)
    }
}
