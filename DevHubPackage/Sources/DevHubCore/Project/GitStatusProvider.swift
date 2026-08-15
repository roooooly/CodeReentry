import Foundation

public struct GitStatus: Sendable, Equatable {
    public let branch: String
    public let lastCommitSubject: String
    public let dirtyFileCount: Int
    public init(branch: String, lastCommitSubject: String, dirtyFileCount: Int) {
        self.branch = branch
        self.lastCommitSubject = lastCommitSubject
        self.dirtyFileCount = dirtyFileCount
    }
}

public struct GitStatusProvider: Sendable {
    public init() {}

    public func status(at url: URL) async throws -> GitStatus? {
        let dotGit = url.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: dotGit.path) else { return nil }

        let branch = (try await runGit(args: ["rev-parse", "--abbrev-ref", "HEAD"], at: url))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lastCommit = (try await runGit(args: ["log", "-1", "--pretty=%s"], at: url))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let dirty = (try await runGit(args: ["status", "--porcelain"], at: url))?
            .split(separator: "\n")
            .filter { !$0.isEmpty }
            .count ?? 0

        guard let b = branch, let c = lastCommit else { return nil }
        return GitStatus(branch: b, lastCommitSubject: c, dirtyFileCount: dirty)
    }

    private func runGit(args: [String], at url: URL) async throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = url

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        return try await withCheckedThrowingContinuation { cont in
            do {
                try process.run()
                process.terminationHandler = { _ in
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: String(data: data, encoding: .utf8))
                }
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
