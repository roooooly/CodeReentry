import Foundation
import Testing
import DevHubCore
@testable import DevHub

@Suite("ReentryTrialCoordinator")
@MainActor
struct ReentryTrialCoordinatorTests {
    @Test("start keeps only anonymous metadata and measures elapsed seconds")
    func startsAnonymousTimer() throws {
        var current = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = ReentryTrialCoordinator(
            store: ReentryTrialStore(fileURL: nil),
            now: { current }
        )

        try coordinator.start(
            projectStableID: "private-project-id",
            toolIdentifier: "gemini",
            sessionStartedAt: current.addingTimeInterval(-8 * 86_400)
        )
        let trial = try #require(coordinator.activeTrial)
        current = current.addingTimeInterval(12.2)

        #expect(trial.projectSlot.hasPrefix("p"))
        #expect(!trial.projectSlot.contains("private-project-id"))
        #expect(trial.tool == .geminiCLI)
        #expect(trial.sessionAge == .older)
        #expect(coordinator.elapsedSeconds() == 13)
        #expect(throws: ReentryTrialCoordinatorError.activeTrialExists) {
            try coordinator.start(
                projectStableID: "another", toolIdentifier: "codex",
                sessionStartedAt: current
            )
        }
    }

    @Test("complete writes one valid result, refreshes summary, and clears timer")
    func completesTrial() async throws {
        var current = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = ReentryTrialCoordinator(
            store: ReentryTrialStore(fileURL: nil),
            now: { current }
        )
        try coordinator.start(
            projectStableID: "project-a",
            toolIdentifier: "github-copilot-cli",
            sessionStartedAt: current
        )
        current = current.addingTimeInterval(44.1)
        #expect(try coordinator.captureElapsed() == 45)
        current = current.addingTimeInterval(300)
        #expect(coordinator.elapsedSeconds() == 45)

        try await coordinator.complete(
            baselineSeconds: 120,
            outcome: .correct,
            reductionBand: .high,
            crossProjectContext: false,
            failure: .none
        )

        #expect(coordinator.activeTrial == nil)
        #expect(coordinator.records.count == 1)
        #expect(coordinator.records[0].input.tool == .githubCopilot)
        #expect(coordinator.records[0].input.reentrySeconds == 45)
        #expect(coordinator.summary.attemptCount == 1)
        #expect(coordinator.summary.medianReentrySeconds == 45)
        #expect(coordinator.hasStoredEvidence)
    }

    @Test("unsupported tools and completion without a timer fail explicitly")
    func rejectsInvalidLifecycle() async {
        let coordinator = ReentryTrialCoordinator(store: ReentryTrialStore(fileURL: nil))

        #expect(throws: ReentryTrialCoordinatorError.unsupportedTool("unknown")) {
            try coordinator.start(
                projectStableID: "project", toolIdentifier: "unknown",
                sessionStartedAt: Date()
            )
        }
        await #expect(throws: ReentryTrialCoordinatorError.noActiveTrial) {
            try await coordinator.complete(
                baselineSeconds: 120, outcome: .correct, reductionBand: .high,
                crossProjectContext: false, failure: .none
            )
        }

        try? coordinator.start(
            projectStableID: "project", toolIdentifier: "codex",
            sessionStartedAt: Date()
        )
        await #expect(throws: ReentryTrialCoordinatorError.timerStillRunning) {
            try await coordinator.complete(
                baselineSeconds: 120, outcome: .correct, reductionBand: .high,
                crossProjectContext: false, failure: .none
            )
        }
    }

    @Test("deleting evidence clears completed records and an active timer")
    func deletesEvidence() async throws {
        var current = Date(timeIntervalSince1970: 1_700_000_000)
        let coordinator = ReentryTrialCoordinator(
            store: ReentryTrialStore(fileURL: nil),
            now: { current }
        )
        try coordinator.start(
            projectStableID: "project-a", toolIdentifier: "codex",
            sessionStartedAt: current
        )
        current = current.addingTimeInterval(10)
        try coordinator.captureElapsed()
        try await coordinator.complete(
            baselineSeconds: 120, outcome: .correct, reductionBand: .high,
            crossProjectContext: false, failure: .none
        )
        try coordinator.start(
            projectStableID: "project-b", toolIdentifier: "gemini-cli",
            sessionStartedAt: current
        )
        try coordinator.captureElapsed()

        try await coordinator.deleteAllEvidence()

        #expect(coordinator.activeTrial == nil)
        #expect(coordinator.capturedElapsedSeconds == nil)
        #expect(coordinator.records.isEmpty)
        #expect(coordinator.summary == .empty)
        #expect(!coordinator.hasStoredEvidence)
    }

    @Test("malformed evidence stays visible to management and can be deleted")
    func deletesMalformedEvidence() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("reentry-coordinator-malformed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("reentry-trials.csv")
        try "not,the,expected,schema\n".write(to: file, atomically: true, encoding: .utf8)
        let coordinator = ReentryTrialCoordinator(
            store: ReentryTrialStore(fileURL: file)
        )

        await coordinator.refresh()

        #expect(coordinator.hasStoredEvidence)
        #expect(coordinator.records.isEmpty)
        #expect(coordinator.errorMessage != nil)

        try await coordinator.deleteAllEvidence()

        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!coordinator.hasStoredEvidence)
        #expect(coordinator.errorMessage == nil)
    }
}
