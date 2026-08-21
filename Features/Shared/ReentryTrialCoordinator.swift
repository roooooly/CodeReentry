import Foundation
import DevHubCore

struct ActiveReentryTrial: Equatable, Identifiable {
    let id: UUID
    let projectSlot: String
    let tool: ReentryTrialTool
    let sessionAge: ReentryTrialSessionAge
    let startedAt: Date
}

enum ReentryTrialCoordinatorError: Error, LocalizedError, Equatable {
    case activeTrialExists
    case unsupportedTool(String)
    case noActiveTrial
    case timerStillRunning

    var errorDescription: String? {
        switch self {
        case .activeTrialExists:
            String(localized: "已有一次恢复测量正在进行。请先记录或放弃它。")
        case .unsupportedTool(let tool):
            String(localized: "暂不支持测量工具：\(tool)")
        case .noActiveTrial:
            String(localized: "没有正在进行的恢复测量。")
        case .timerStillRunning:
            String(localized: "请先停止计时，再保存恢复结果。")
        }
    }
}

/// Owns the deliberately manual recovery timer. Its active state contains only
/// anonymous metadata and is not persisted across launches; completed evidence
/// is delegated to the strict local CSV store.
@Observable
@MainActor
final class ReentryTrialCoordinator {
    private let store: ReentryTrialStore
    private let now: @MainActor () -> Date

    private(set) var activeTrial: ActiveReentryTrial?
    /// Frozen as soon as the user says context is ready, before the form opens.
    private(set) var capturedElapsedSeconds: Int?
    private(set) var records: [ReentryTrialRecord] = []
    private(set) var summary: ReentryTrialSummary = .empty
    private(set) var hasStoredEvidence = false
    private(set) var errorMessage: String?

    init(
        store: ReentryTrialStore,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.store = store
        self.now = now
    }

    func refresh() async {
        hasStoredEvidence = await store.hasStoredEvidence()
        do {
            records = try await store.records()
            summary = ReentryTrialStore.summarize(records)
            errorMessage = nil
        } catch {
            records = []
            summary = .empty
            errorMessage = error.localizedDescription
        }
    }

    func start(
        projectStableID: String,
        toolIdentifier: String,
        sessionStartedAt: Date
    ) throws {
        guard activeTrial == nil else {
            throw ReentryTrialCoordinatorError.activeTrialExists
        }
        guard let tool = ReentryTrialTool(sessionToolIdentifier: toolIdentifier) else {
            throw ReentryTrialCoordinatorError.unsupportedTool(toolIdentifier)
        }
        let current = now()
        activeTrial = ActiveReentryTrial(
            id: UUID(),
            projectSlot: ReentryTrialStore.anonymousProjectSlot(stableID: projectStableID),
            tool: tool,
            sessionAge: .classify(sessionStartedAt: sessionStartedAt, now: current),
            startedAt: current
        )
        capturedElapsedSeconds = nil
        errorMessage = nil
    }

    func elapsedSeconds(at date: Date? = nil) -> Int {
        guard let activeTrial else { return 0 }
        if let capturedElapsedSeconds { return capturedElapsedSeconds }
        return max(1, Int((date ?? now()).timeIntervalSince(activeTrial.startedAt).rounded(.up)))
    }

    /// Freezes the recovery duration at the explicit confirmation moment so
    /// time spent filling the outcome form cannot inflate the product metric.
    @discardableResult
    func captureElapsed() throws -> Int {
        guard activeTrial != nil else {
            throw ReentryTrialCoordinatorError.noActiveTrial
        }
        if let capturedElapsedSeconds { return capturedElapsedSeconds }
        let captured = elapsedSeconds()
        capturedElapsedSeconds = captured
        return captured
    }

    func complete(
        baselineSeconds: Int,
        outcome: ReentryTrialOutcome,
        reductionBand: ReentryTrialReductionBand,
        crossProjectContext: Bool,
        failure: ReentryTrialFailure
    ) async throws {
        guard let activeTrial else {
            throw ReentryTrialCoordinatorError.noActiveTrial
        }
        guard capturedElapsedSeconds != nil else {
            throw ReentryTrialCoordinatorError.timerStillRunning
        }
        let input = ReentryTrialInput(
            projectSlot: activeTrial.projectSlot,
            tool: activeTrial.tool,
            sessionAge: activeTrial.sessionAge,
            baselineSeconds: baselineSeconds,
            reentrySeconds: elapsedSeconds(),
            outcome: outcome,
            reductionBand: reductionBand,
            crossProjectContext: crossProjectContext,
            failure: failure
        )
        _ = try await store.record(input, at: now())
        self.activeTrial = nil
        capturedElapsedSeconds = nil
        await refresh()
    }

    /// Clears both completed local evidence and any unfinished in-memory timer.
    /// State changes only after the file operation succeeds.
    func deleteAllEvidence() async throws {
        do {
            try await store.deleteAllRecords()
            activeTrial = nil
            capturedElapsedSeconds = nil
            records = []
            summary = .empty
            hasStoredEvidence = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func cancelActive() {
        activeTrial = nil
        capturedElapsedSeconds = nil
        errorMessage = nil
    }
}
