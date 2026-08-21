import Foundation

public enum ReentryTrialTool: String, CaseIterable, Sendable {
    case claudeCode = "claude-code"
    case codex
    case zcode
    case opencode
    case kimi
    case geminiCLI = "gemini-cli"
    case githubCopilot = "github-copilot"

    public init?(sessionToolIdentifier: String) {
        switch sessionToolIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude", "claude-code": self = .claudeCode
        case "codex": self = .codex
        case "zcode": self = .zcode
        case "opencode": self = .opencode
        case "kimi": self = .kimi
        case "gemini", "gemini-cli": self = .geminiCLI
        case "copilot", "github-copilot", "github-copilot-cli": self = .githubCopilot
        default: return nil
        }
    }
}

public enum ReentryTrialSessionAge: String, CaseIterable, Sendable {
    case recent
    case older

    public static func classify(sessionStartedAt: Date, now: Date) -> Self {
        now.timeIntervalSince(sessionStartedAt) <= 7 * 86_400 ? .recent : .older
    }
}

public enum ReentryTrialOutcome: String, CaseIterable, Sendable {
    case correct
    case wrongProject = "wrong-project"
    case wrongSession = "wrong-session"
    case unusableContext = "unusable-context"
    case launchFailed = "launch-failed"
}

public enum ReentryTrialReductionBand: String, CaseIterable, Sendable {
    case zero = "0"
    case low = "1-29"
    case medium = "30-69"
    case high = "70-99"
    case complete = "100"

    public var midpoint: Int {
        switch self {
        case .zero: 0
        case .low: 15
        case .medium: 50
        case .high: 85
        case .complete: 100
        }
    }
}

public enum ReentryTrialFailure: String, CaseIterable, Sendable {
    case none
    case pathMissing = "path-missing"
    case sessionNotFound = "session-not-found"
    case readerUnsupported = "reader-unsupported"
    case resumeUnsupported = "resume-unsupported"
    case wrongBinding = "wrong-binding"
    case staleSummary = "stale-summary"
    case toolLaunch = "tool-launch"
    case other
}

public struct ReentryTrialInput: Equatable, Sendable {
    public let projectSlot: String
    public let tool: ReentryTrialTool
    public let sessionAge: ReentryTrialSessionAge
    public let baselineSeconds: Int
    public let reentrySeconds: Int
    public let outcome: ReentryTrialOutcome
    public let reductionBand: ReentryTrialReductionBand
    public let crossProjectContext: Bool
    public let failure: ReentryTrialFailure

    public init(
        projectSlot: String,
        tool: ReentryTrialTool,
        sessionAge: ReentryTrialSessionAge,
        baselineSeconds: Int,
        reentrySeconds: Int,
        outcome: ReentryTrialOutcome,
        reductionBand: ReentryTrialReductionBand,
        crossProjectContext: Bool,
        failure: ReentryTrialFailure
    ) {
        self.projectSlot = projectSlot
        self.tool = tool
        self.sessionAge = sessionAge
        self.baselineSeconds = baselineSeconds
        self.reentrySeconds = reentrySeconds
        self.outcome = outcome
        self.reductionBand = reductionBand
        self.crossProjectContext = crossProjectContext
        self.failure = failure
    }
}

public struct ReentryTrialRecord: Equatable, Sendable, Identifiable {
    public let attemptID: Int
    public let recordedAt: Date
    public let input: ReentryTrialInput

    public var id: Int { attemptID }
}

public struct ReentryTrialSummary: Equatable, Sendable {
    public let attemptCount: Int
    public let recordedSpanDays: Int
    public let projectCount: Int
    public let toolCount: Int
    public let recentCount: Int
    public let olderCount: Int
    public let correctCount: Int
    public let correctPercent: Int
    public let medianBaselineSeconds: Int?
    public let medianReentrySeconds: Int?
    public let relativeImprovementPercent: Int?
    public let medianReductionPercent: Int?
    public let crossProjectIncidentCount: Int
    public let failureCounts: [ReentryTrialFailure: Int]
    public let coverageMet: Bool
    public let targetsMet: Bool

    public static let empty = ReentryTrialSummary(
        attemptCount: 0, recordedSpanDays: 0, projectCount: 0, toolCount: 0,
        recentCount: 0, olderCount: 0, correctCount: 0, correctPercent: 0,
        medianBaselineSeconds: nil, medianReentrySeconds: nil,
        relativeImprovementPercent: nil, medianReductionPercent: nil,
        crossProjectIncidentCount: 0, failureCounts: [:],
        coverageMet: false, targetsMet: false
    )
}

public enum ReentryTrialError: Error, LocalizedError, Equatable {
    case invalidProjectSlot
    case invalidDuration
    case inconsistentOutcome
    case symbolicLink
    case unexpectedFileType
    case unexpectedSchema
    case invalidRow(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidProjectSlot:
            "Project slot must be anonymous, such as p1."
        case .invalidDuration:
            "Baseline and CodeReentry durations must be positive."
        case .inconsistentOutcome:
            "Outcome, failure category, and cross-project context are inconsistent."
        case .symbolicLink:
            "Refusing to read or write re-entry evidence through a symbolic link."
        case .unexpectedFileType:
            "Refusing to manage re-entry evidence at a path that is not a regular file."
        case .unexpectedSchema:
            "The local re-entry evidence file has an unexpected schema."
        case .invalidRow(let row):
            "The local re-entry evidence file contains an invalid row at line \(row)."
        }
    }
}

public actor ReentryTrialStore {
    public static let csvHeader = "attempt_id,recorded_at,recorded_epoch,project_slot,tool,session_age,baseline_seconds,devhub_seconds,outcome,repeated_background_reduction_band,cross_project_context,failure_category"

    public nonisolated let fileURL: URL?
    private var inMemoryRecords: [ReentryTrialRecord] = []

    /// Pass nil for an in-memory store (used by isolated demo mode and tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    public static var defaultFileURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("CodeReentry", isDirectory: true)
            .appendingPathComponent("reentry-trials.csv")
    }

    /// A deterministic anonymous slot. Only the derived p-number reaches a record;
    /// project names, paths, stable IDs, and session IDs are never stored there.
    public nonisolated static func anonymousProjectSlot(stableID: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in stableID.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return "p\((hash % 900_000_000) + 100_000_000)"
    }

    public func records() throws -> [ReentryTrialRecord] {
        guard let fileURL else { return inMemoryRecords }
        return try readRecords(from: fileURL)
    }

    /// Reports whether there is evidence to manage without requiring the CSV
    /// to parse successfully. This keeps the delete control available when a
    /// regular evidence file is malformed or from an incompatible version.
    public func hasStoredEvidence() -> Bool {
        guard let fileURL else { return !inMemoryRecords.isEmpty }
        return FileManager.default.fileExists(atPath: fileURL.path)
    }

    @discardableResult
    public func record(_ input: ReentryTrialInput, at date: Date = Date()) throws -> ReentryTrialRecord {
        try Self.validate(input)
        var existing = try records()
        let record = ReentryTrialRecord(
            attemptID: existing.count + 1,
            recordedAt: date,
            input: input
        )
        existing.append(record)
        if let fileURL {
            try write(existing, to: fileURL)
        } else {
            inMemoryRecords = existing
        }
        return record
    }

    public func summary() throws -> ReentryTrialSummary {
        Self.summarize(try records())
    }

    /// Removes only this store's evidence file. The containing application-
    /// support directory is retained because it may hold other owned data.
    public func deleteAllRecords() throws {
        guard let fileURL else {
            inMemoryRecords = []
            return
        }
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path), isSymbolicLink(directory) {
            throw ReentryTrialError.symbolicLink
        }
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        guard !isSymbolicLink(fileURL) else { throw ReentryTrialError.symbolicLink }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ReentryTrialError.unexpectedFileType
        }
        try fileManager.removeItem(at: fileURL)
    }

    public nonisolated static func summarize(_ records: [ReentryTrialRecord]) -> ReentryTrialSummary {
        guard !records.isEmpty else { return .empty }
        let epochs = records.map { Int($0.recordedAt.timeIntervalSince1970) }
        let span = ((epochs.max() ?? 0) - (epochs.min() ?? 0)) / 86_400 + 1
        let correct = records.filter { $0.input.outcome == .correct }.count
        let correctPercent = Int(
            (Double(correct) * 100 / Double(records.count)).rounded(.toNearestOrEven)
        )
        let baseline = median(records.map(\.input.baselineSeconds))
        let reentry = median(records.map(\.input.reentrySeconds))
        let improvement = baseline > 0
            ? Int(
                (Double(baseline - reentry) * 100 / Double(baseline))
                    .rounded(.toNearestOrEven)
            )
            : 0
        let reduction = median(records.map { $0.input.reductionBand.midpoint })
        let crossProject = records.filter(\.input.crossProjectContext).count
        var failures: [ReentryTrialFailure: Int] = [:]
        for record in records where record.input.failure != .none {
            failures[record.input.failure, default: 0] += 1
        }
        let recent = records.filter { $0.input.sessionAge == .recent }.count
        let older = records.filter { $0.input.sessionAge == .older }.count
        let projectCount = Set(records.map(\.input.projectSlot)).count
        let toolCount = Set(records.map(\.input.tool)).count
        let coverage = records.count >= 10 && projectCount >= 3 && toolCount >= 2
            && recent > 0 && older > 0 && span >= 7
        let targets = coverage && correctPercent >= 90 && reentry <= 60
            && improvement >= 50 && reduction >= 70 && crossProject == 0

        return ReentryTrialSummary(
            attemptCount: records.count, recordedSpanDays: span,
            projectCount: projectCount, toolCount: toolCount,
            recentCount: recent, olderCount: older,
            correctCount: correct, correctPercent: correctPercent,
            medianBaselineSeconds: baseline, medianReentrySeconds: reentry,
            relativeImprovementPercent: improvement,
            medianReductionPercent: reduction,
            crossProjectIncidentCount: crossProject,
            failureCounts: failures, coverageMet: coverage, targetsMet: targets
        )
    }

    private nonisolated static func median(_ values: [Int]) -> Int {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Int(
                (Double(sorted[middle - 1] + sorted[middle]) / 2)
                    .rounded(.toNearestOrEven)
            )
        }
        return sorted[middle]
    }

    private nonisolated static func validate(_ input: ReentryTrialInput) throws {
        guard isAnonymousProjectSlot(input.projectSlot) else {
            throw ReentryTrialError.invalidProjectSlot
        }
        guard input.baselineSeconds > 0, input.reentrySeconds > 0 else {
            throw ReentryTrialError.invalidDuration
        }
        guard (input.outcome == .correct) == (input.failure == .none),
              !(input.outcome == .correct && input.crossProjectContext) else {
            throw ReentryTrialError.inconsistentOutcome
        }
    }

    private nonisolated static func isAnonymousProjectSlot(_ slot: String) -> Bool {
        guard slot.first == "p", slot.count > 1 else { return false }
        let digits = slot.dropFirst()
        return digits.first != "0" && digits.allSatisfy(\.isNumber)
    }

    private func readRecords(from url: URL) throws -> [ReentryTrialRecord] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        guard !isSymbolicLink(url) else { throw ReentryTrialError.symbolicLink }
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.first == Self.csvHeader else { throw ReentryTrialError.unexpectedSchema }
        var result: [ReentryTrialRecord] = []
        for (offset, line) in lines.dropFirst().enumerated() {
            let lineNumber = offset + 2
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 12,
                  let attemptID = Int(fields[0]), attemptID == result.count + 1,
                  !fields[1].isEmpty,
                  let epoch = Int(fields[2]), epoch > 0,
                  let tool = ReentryTrialTool(rawValue: fields[4]),
                  let age = ReentryTrialSessionAge(rawValue: fields[5]),
                  let baseline = Int(fields[6]),
                  let reentry = Int(fields[7]),
                  let outcome = ReentryTrialOutcome(rawValue: fields[8]),
                  let reduction = ReentryTrialReductionBand(rawValue: fields[9]),
                  ["no", "yes"].contains(fields[10]),
                  let failure = ReentryTrialFailure(rawValue: fields[11]) else {
                throw ReentryTrialError.invalidRow(lineNumber)
            }
            let input = ReentryTrialInput(
                projectSlot: fields[3], tool: tool, sessionAge: age,
                baselineSeconds: baseline, reentrySeconds: reentry,
                outcome: outcome, reductionBand: reduction,
                crossProjectContext: fields[10] == "yes", failure: failure
            )
            do {
                try Self.validate(input)
            } catch {
                throw ReentryTrialError.invalidRow(lineNumber)
            }
            result.append(ReentryTrialRecord(
                attemptID: attemptID,
                recordedAt: Date(timeIntervalSince1970: TimeInterval(epoch)),
                input: input
            ))
        }
        return result
    }

    private func write(_ records: [ReentryTrialRecord], to url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path), isSymbolicLink(url) {
            throw ReentryTrialError.symbolicLink
        }
        let directory = url.deletingLastPathComponent()
        if fileManager.fileExists(atPath: directory.path), isSymbolicLink(directory) {
            throw ReentryTrialError.symbolicLink
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var lines = [Self.csvHeader]
        lines.append(contentsOf: records.map { record in
            let input = record.input
            return [
                String(record.attemptID),
                formatter.string(from: record.recordedAt),
                String(Int(record.recordedAt.timeIntervalSince1970)),
                input.projectSlot, input.tool.rawValue, input.sessionAge.rawValue,
                String(input.baselineSeconds), String(input.reentrySeconds),
                input.outcome.rawValue, input.reductionBand.rawValue,
                input.crossProjectContext ? "yes" : "no", input.failure.rawValue,
            ].joined(separator: ",")
        })
        try (lines.joined(separator: "\n") + "\n").write(
            to: url, atomically: true, encoding: .utf8
        )
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
