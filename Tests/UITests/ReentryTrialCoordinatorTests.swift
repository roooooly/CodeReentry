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
    }
}
