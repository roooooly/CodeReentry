import Testing
import Foundation
@testable import DevHubCore

@Suite("InjectionManager")
struct InjectionManagerTests {

    @Test("render → no secret → cap ok → returns .cliFlag content")
    func cleanToCliFlag() {
        let result = InjectionManager.prepare(
            context: "# ExampleApp\n项目用 SwiftUI",
            lastSessionSummary: nil,
            gitStatus: nil,
            preferredMode: .cliFlag
        )
        #expect(result.mode == .cliFlag)
        #expect(result.scannedSecrets.isEmpty)
        #expect(result.truncated == false)
        #expect(result.rendered.contains("# ExampleApp"))
    }

    @Test("render → secret present → positional blocked, fallback to cliFlag")
    func secretBlocksPositional() {
        let result = InjectionManager.prepare(
            context: "api_key=sk-abc AKIAIOSFODNN7EXAMPLE",
            lastSessionSummary: nil, gitStatus: nil,
            preferredMode: .positionalArg
        )
        #expect(result.scannedSecrets.isEmpty == false)
        #expect(result.mode == .cliFlag)
        #expect(result.fellBackFromPositional == true)
    }

    @Test("render → secret present + cannot cliFlag → fallback to clipboard")
    func secretForcesClipboard() {
        let result = InjectionManager.prepare(
            context: "AKIAIOSFODNN7EXAMPLE",
            lastSessionSummary: nil, gitStatus: nil,
            preferredMode: .positionalArg,
            allowCliFlagFallback: false
        )
        #expect(result.mode == .clipboard)
    }

    @Test("render → >8KB → truncate + suffix")
    func truncate() {
        let huge = String(repeating: "a", count: 10_000)
        let result = InjectionManager.prepare(
            context: huge, lastSessionSummary: nil, gitStatus: nil,
            preferredMode: .cliFlag
        )
        #expect(result.truncated == true)
        #expect(result.rendered.utf8.count <= 8192)
        #expect(result.rendered.contains("已截断"))
    }

    @Test("render → exactly 8KB boundary → no truncation")
    func boundaryNoTruncation() {
        // MemoryRenderer adds a `# 项目记忆\n\n` header (8 chars) before context;
        // pick a context size so the rendered output is *exactly* 8192 chars.
        let headerBytes = "# 项目记忆\n\n".utf8.count
        let exactly = String(repeating: "x", count: 8192 - headerBytes)
        let result = InjectionManager.prepare(
            context: exactly, lastSessionSummary: nil, gitStatus: nil,
            preferredMode: .cliFlag
        )
        #expect(result.rendered.utf8.count == 8192)
        #expect(result.truncated == false)
    }

    @Test("8KB cap uses UTF-8 bytes and never splits a Chinese character")
    func multibyteTruncation() {
        let huge = String(repeating: "中", count: 4_000)
        let result = InjectionManager.prepare(
            context: huge, lastSessionSummary: nil, gitStatus: nil,
            preferredMode: .positionalArg
        )

        #expect(result.truncated)
        #expect(result.rendered.utf8.count <= InjectionManager.maxLength)
        #expect(result.rendered.hasSuffix(InjectionManager.truncationSuffix))
        #expect(!result.rendered.contains("�"))
    }

    @Test("empty memory: prepared returns rendered empty-ish, mode unchanged")
    func emptyMemory() {
        let result = InjectionManager.prepare(
            context: "", lastSessionSummary: nil, gitStatus: nil,
            preferredMode: .cliFlag
        )
        #expect(result.mode == .cliFlag)
        #expect(result.scannedSecrets.isEmpty)
    }
}
