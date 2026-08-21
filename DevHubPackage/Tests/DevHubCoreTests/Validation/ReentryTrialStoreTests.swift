import Foundation
import Testing
@testable import DevHubCore

@Suite("ReentryTrialStore")
struct ReentryTrialStoreTests {
    @Test("anonymous project slots are deterministic and contain no source identifier")
    func anonymousSlot() {
        let source = "project-stable-secret-value"
        let first = ReentryTrialStore.anonymousProjectSlot(stableID: source)
        let second = ReentryTrialStore.anonymousProjectSlot(stableID: source)

        #expect(first == second)
        #expect(first.first == "p")
        #expect(Int(first.dropFirst()) != nil)
        #expect(!first.contains(source))
        #expect(first != ReentryTrialStore.anonymousProjectSlot(stableID: "another-project"))
    }

    @Test("records the privacy-safe schema with owner-only permissions")
    func fileRoundTrip() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reentry-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reentry-trials.csv")
        let store = ReentryTrialStore(fileURL: file)
        let input = makeInput(project: "p1", tool: .geminiCLI)

        let recorded = try await store.record(
            input, at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let loaded = try await store.records()
        let text = try String(contentsOf: file, encoding: .utf8)
        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        )

        #expect(recorded.attemptID == 1)
        #expect(loaded == [recorded])
        #expect(permissions.intValue & 0o777 == 0o600)
        #expect(text.hasPrefix(ReentryTrialStore.csvHeader + "\n"))
        #expect(text.contains(",gemini-cli,"))
        #expect(!text.contains("project-stable"))
        #expect(!ReentryTrialStore.csvHeader.contains("path"))
        #expect(!ReentryTrialStore.csvHeader.contains("prompt"))
        #expect(!ReentryTrialStore.csvHeader.contains("content"))
    }

    @Test("summary reproduces the ten-attempt seven-day evidence gate")
    func summaryGate() async throws {
        let store = ReentryTrialStore(fileURL: nil)
        for index in 0..<10 {
            let outcome: ReentryTrialOutcome = index == 9 ? .wrongSession : .correct
            let failure: ReentryTrialFailure = index == 9 ? .sessionNotFound : .none
            try await store.record(
                makeInput(
                    project: "p\((index % 3) + 1)",
                    tool: index.isMultiple(of: 2) ? .codex : .githubCopilot,
                    age: index.isMultiple(of: 2) ? .recent : .older,
                    outcome: outcome,
                    failure: failure
                ),
                at: Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + index * 57_600))
            )
        }

        let summary = try await store.summary()

        #expect(summary.attemptCount == 10)
        #expect(summary.recordedSpanDays == 7)
        #expect(summary.projectCount == 3)
        #expect(summary.toolCount == 2)
        #expect(summary.correctCount == 9)
        #expect(summary.correctPercent == 90)
        #expect(summary.medianBaselineSeconds == 120)
        #expect(summary.medianReentrySeconds == 45)
        // Keep this byte-for-byte compatible with scripts/reentry-trial.sh,
        // whose evidence report truncates 62.5% to 62%.
        #expect(summary.relativeImprovementPercent == 62)
        #expect(summary.medianReductionPercent == 85)
        #expect(summary.failureCounts[.sessionNotFound] == 1)
        #expect(summary.coverageMet)
        #expect(summary.targetsMet)
    }

    @Test("rejects inconsistent, tampered, and symbolic-link evidence")
    func rejectsUnsafeEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reentry-store-unsafe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let memory = ReentryTrialStore(fileURL: nil)
        await #expect(throws: ReentryTrialError.inconsistentOutcome) {
            try await memory.record(makeInput(outcome: .correct, failure: .toolLaunch))
        }

        let tampered = root.appendingPathComponent("tampered.csv")
        try (ReentryTrialStore.csvHeader + "\n2,bad,0,p1,codex,recent,1,1,correct,100,no,none\n")
            .write(to: tampered, atomically: true, encoding: .utf8)
        let tamperedStore = ReentryTrialStore(fileURL: tampered)
        await #expect(throws: ReentryTrialError.invalidRow(2)) {
            _ = try await tamperedStore.records()
        }

        let target = root.appendingPathComponent("target.csv")
        try "private".write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent("link.csv")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkedStore = ReentryTrialStore(fileURL: link)
        await #expect(throws: ReentryTrialError.symbolicLink) {
            _ = try await linkedStore.records()
        }

        let linkedDirectory = root.appendingPathComponent("linked-directory")
        let directoryTarget = root.appendingPathComponent("directory-target")
        try FileManager.default.createDirectory(
            at: directoryTarget, withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedDirectory, withDestinationURL: directoryTarget
        )
        let linkedDirectoryStore = ReentryTrialStore(
            fileURL: linkedDirectory.appendingPathComponent("trials.csv")
        )
        await #expect(throws: ReentryTrialError.symbolicLink) {
            try await linkedDirectoryStore.record(makeInput())
        }
    }

    private func makeInput(
        project: String = "p1",
        tool: ReentryTrialTool = .codex,
        age: ReentryTrialSessionAge = .recent,
        outcome: ReentryTrialOutcome = .correct,
        failure: ReentryTrialFailure = .none
    ) -> ReentryTrialInput {
        ReentryTrialInput(
            projectSlot: project, tool: tool, sessionAge: age,
            baselineSeconds: 120, reentrySeconds: 45,
            outcome: outcome, reductionBand: .high,
            crossProjectContext: false, failure: failure
        )
    }
}
