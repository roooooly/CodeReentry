import Testing
import Foundation
@testable import DevHubCore

@Suite("ToolDetector")
struct ToolDetectorTests {

    let detector = ToolDetector()

    @Test("explicit detectPath wins when file exists")
    func explicitDetectPathFound() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-detector-\(UUID().uuidString)-exe")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = detector.probe(
            executableHint: "does-not-matter",
            detectPath: tmp.path,
            launchCommand: "ignored"
        )
        guard case .found(let abs) = result else {
            Issue.record("expected found"); return
        }
        #expect(abs == tmp.path)
    }

    @Test("missing explicit detectPath does not fall back to another executable")
    func missingExplicitPathIsAuthoritative() {
        let result = detector.probe(
            executableHint: "/bin/ls",
            detectPath: "/missing/code-reentry/tool",
            launchCommand: "/bin/ls"
        )

        #expect(result == .notFound)
    }

    @Test("absolute executablePath found via FileManager")
    func absoluteExecutableFound() throws {
        // /bin/ls 一定存在
        let result = detector.probe(
            executableHint: "/bin/ls",
            detectPath: nil,
            launchCommand: nil
        )
        if case .found(let abs) = result {
            #expect(abs == "/bin/ls")
        } else {
            Issue.record("expected /bin/ls found")
        }
    }

    @Test("bare name resolves via PATH lookup")
    func bareNamePathLookup() {
        // "ls" 应在 /bin/ls 或 /usr/bin 中
        let result = detector.probe(
            executableHint: "ls",
            detectPath: nil,
            launchCommand: nil
        )
        if case .found(let abs) = result {
            #expect(abs.hasSuffix("/ls"))
        } else {
            Issue.record("expected ls found in PATH dirs")
        }
    }

    @Test("nonexistent path → notFound")
    func notFound() {
        let result = detector.probe(
            executableHint: "/this/does/not/exist-xyz",
            detectPath: nil,
            launchCommand: nil
        )
        #expect(result == .notFound)
    }

    @Test("launchCommand first segment is used as fallback")
    func launchCommandFallback() {
        let result = detector.probe(
            executableHint: nil,
            detectPath: nil,
            launchCommand: "/bin/ls --color"
        )
        if case .found(let abs) = result {
            #expect(abs == "/bin/ls")
        } else {
            Issue.record("expected fallback to launchCommand first segment")
        }
    }

    @Test("missing configured launchCommand does not fall back to adapter default")
    func missingLaunchCommandIsAuthoritative() {
        let result = detector.probe(
            executableHint: "/bin/ls",
            detectPath: nil,
            launchCommand: "/missing/code-reentry/tool"
        )

        #expect(result == .notFound)
    }

    @Test("quoted launchCommand path with spaces is parsed as one executable")
    func quotedLaunchCommandPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("code reentry detector \(UUID().uuidString)")
        let executable = directory.appendingPathComponent("tool")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: executable.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = detector.probe(
            executableHint: nil,
            detectPath: nil,
            launchCommand: "\"\(executable.path)\" --resume"
        )

        #expect(result == .found(absolutePath: executable.path))
    }

    @Test("searchPATH returns nil for unknown name")
    func searchPATHUnknown() {
        #expect(ToolDetector.searchPATH(name: "devhub-totally-nonexistent-bin-xyz") == nil)
    }

    @Test("searchPATH finds known binary")
    func searchPATHKnown() {
        #expect(ToolDetector.searchPATH(name: "ls") != nil)
    }
}
