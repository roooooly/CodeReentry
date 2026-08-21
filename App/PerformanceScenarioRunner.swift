import AppKit
import Darwin
import Foundation
import SwiftData
import DevHubCore

struct PerformanceScenarioConfiguration: Equatable {
    let profile: URL
    let cycles: Int
    let idleSeconds: Int
    let recoverySeconds: Int

    init?(environment: [String: String]) {
        guard environment["DEVHUB_PERFORMANCE_SCENARIO"] == "1",
              let profilePath = environment["DEVHUB_PERFORMANCE_PROFILE"],
              !profilePath.isEmpty else {
            return nil
        }
        let cycles = Int(environment["DEVHUB_PERFORMANCE_CYCLES"] ?? "10") ?? 0
        let idle = Int(environment["DEVHUB_PERFORMANCE_IDLE_SECONDS"] ?? "300") ?? -1
        let recovery = Int(environment["DEVHUB_PERFORMANCE_RECOVERY_SECONDS"] ?? "10") ?? -1
        guard (1...100).contains(cycles), (0...600).contains(idle), (0...300).contains(recovery) else {
            return nil
        }
        self.profile = URL(fileURLWithPath: profilePath, isDirectory: true).standardizedFileURL
        self.cycles = cycles
        self.idleSeconds = idle
        self.recoverySeconds = recovery
    }
}

private struct PerformanceScenarioReport: Codable {
    let schemaVersion: Int
    let succeeded: Bool
    let fixtureScale: String
    let cycles: Int
    let projectCount: Int
    let sessionCount: Int
    let idleSeconds: Int
    let initialScanMilliseconds: Int
    let initialPreparationMilliseconds: Int
    let initialDiscoveryMilliseconds: Int
    let initialProjectMatchingMilliseconds: Int
    let initialWritingMilliseconds: Int
    let initialWritePreparationMilliseconds: Int
    let initialWriteModelMutationMilliseconds: Int
    let initialWriteSaveMilliseconds: Int
    let initialWriteCacheMilliseconds: Int
    let repeatedRefreshMilliseconds: [Int]
    let navigationTransitions: Int
    let settingsWindowOpenCount: Int
    let recoverySeconds: Int
    let failureCode: String?
}

private struct SyntheticPerformanceSessionReader: SessionReader {
    let toolId = "devhub-performance-fixture"
    let projectPaths: [String]
    let sessionsPerProject: Int
    let sourcePaths: [String: String]

    func discover() async throws -> [DiscoveredSession] {
        generateSessions()
    }

    func discover(knownFiles: [String: Date]) async throws -> [DiscoveredSession] {
        knownFiles.isEmpty ? generateSessions() : []
    }

    func load(_ id: String) async throws -> SessionDetail {
        SessionDetail(
            tool: toolId,
            toolSessionId: id,
            cwd: "",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            messages: []
        )
    }

    private func generateSessions() -> [DiscoveredSession] {
        let tools = ["claude-code", "codex", "zcode", "opencode", "kimi"]
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var result: [DiscoveredSession] = []
        result.reserveCapacity(projectPaths.count * sessionsPerProject)
        for (projectIndex, projectPath) in projectPaths.enumerated() {
            for sessionOffset in 0..<sessionsPerProject {
                let globalIndex = projectIndex * sessionsPerProject + sessionOffset
                let tool = tools[globalIndex % tools.count]
                guard let sourcePath = sourcePaths[tool] else { continue }
                let updatedAt = baseDate.addingTimeInterval(TimeInterval(globalIndex * 30))
                result.append(DiscoveredSession(
                    tool: tool,
                    toolSessionId: String(format: "fixture-%@-%06d", tool, globalIndex + 1),
                    sourcePath: sourcePath,
                    projectCwd: projectPath,
                    startedAt: updatedAt.addingTimeInterval(-600),
                    updatedAt: updatedAt,
                    messageCount: globalIndex % 40 + 1,
                    title: "Synthetic recovery session \(globalIndex + 1)",
                    preview: "Deterministic fixture preview without project or conversation content."
                ))
            }
        }
        return result
    }
}

@MainActor
enum PerformanceScenarioRunner {
    private static var hasStarted = false

    static func runIfRequested(
        dependencies: AppDependencies,
        modelContext: ModelContext,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async {
        guard !hasStarted,
              let configuration = PerformanceScenarioConfiguration(environment: environment) else {
            return
        }
        hasStarted = true
        do {
            try await run(
                configuration: configuration,
                dependencies: dependencies,
                modelContext: modelContext
            )
        } catch {
            NSLog("[performance] isolated scenario failed")
            try? writePhase("failed")
            try? writeReport(PerformanceScenarioReport(
                schemaVersion: 1,
                succeeded: false,
                fixtureScale: "unknown",
                cycles: configuration.cycles,
                projectCount: 0,
                sessionCount: 0,
                idleSeconds: configuration.idleSeconds,
                initialScanMilliseconds: 0,
                initialPreparationMilliseconds: 0,
                initialDiscoveryMilliseconds: 0,
                initialProjectMatchingMilliseconds: 0,
                initialWritingMilliseconds: 0,
                initialWritePreparationMilliseconds: 0,
                initialWriteModelMutationMilliseconds: 0,
                initialWriteSaveMilliseconds: 0,
                initialWriteCacheMilliseconds: 0,
                repeatedRefreshMilliseconds: [],
                navigationTransitions: 0,
                settingsWindowOpenCount: 0,
                recoverySeconds: configuration.recoverySeconds,
                failureCode: "scenario-failed"
            ))
            exit(EXIT_FAILURE)
        }
    }

    private static var scenarioDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("DevHub", isDirectory: true)
            .appendingPathComponent("PerformanceScenario", isDirectory: true)
    }

    private static func writePhase(_ phase: String) throws {
        try FileManager.default.createDirectory(
            at: scenarioDirectory,
            withIntermediateDirectories: true
        )
        try (phase + "\n").write(
            to: scenarioDirectory.appendingPathComponent("phase.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func writeReport(_ report: PerformanceScenarioReport) throws {
        try FileManager.default.createDirectory(
            at: scenarioDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(
            to: scenarioDirectory.appendingPathComponent("report.json"),
            options: .atomic
        )
    }

    private static func manifestURL(in profile: URL) -> URL {
        profile
            .appendingPathComponent("SyntheticFixtures", isDirectory: true)
            .appendingPathComponent(PerformanceFixtureManifest.fileName)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - start
        return Int(duration.components.seconds * 1_000)
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func pause(milliseconds: UInt64 = 60) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }

    private static func run(
        configuration: PerformanceScenarioConfiguration,
        dependencies: AppDependencies,
        modelContext: ModelContext
    ) async throws {
        let actualHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        guard actualHome == configuration.profile else {
            throw CocoaError(.fileReadNoPermission)
        }
        let manifest = try JSONDecoder().decode(
            PerformanceFixtureManifest.self,
            from: Data(contentsOf: manifestURL(in: configuration.profile))
        )
        guard manifest.schemaVersion == PerformanceFixtureManifest.schemaVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let projects = try modelContext.fetch(FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\.stableId)]
        ))
        let indexedSessionCount = try modelContext.fetchCount(FetchDescriptor<SessionIndex>())
        guard projects.count == manifest.projectCount,
              manifest.initialIndexState == "empty",
              indexedSessionCount == 0,
              projects.allSatisfy({ $0.stableId.hasPrefix("fixture-project-") }) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let tools = ["claude-code", "codex", "zcode", "opencode", "kimi"]
        var sourcePaths: [String: String] = [:]
        for tool in tools {
            let source = configuration.profile
                .appendingPathComponent("SyntheticFixtures", isDirectory: true)
                .appendingPathComponent("SessionSources", isDirectory: true)
                .appendingPathComponent("\(tool)-synthetic-session.jsonl")
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            sourcePaths[tool] = source.path
        }
        let reader = SyntheticPerformanceSessionReader(
            projectPaths: projects.map(\.path),
            sessionsPerProject: manifest.sessionsPerProject,
            sourcePaths: sourcePaths
        )

        try writePhase("idle")
        if configuration.idleSeconds > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(configuration.idleSeconds) * 1_000_000_000
            )
        }

        // The production scan is only started by an explicit button press.
        // Wake the synthetic app from App Nap before timing that operation;
        // otherwise a launch-only test measures a background timer that the
        // product never uses rather than the foreground re-entry path.
        NSApp.activate(ignoringOtherApps: true)
        let userActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,
            reason: "DevHub synthetic user-initiated session scan"
        )
        defer { ProcessInfo.processInfo.endActivity(userActivity) }
        try await pause(milliseconds: 250)
        try writePhase("initial-scan")
        await Task.yield()
        let writer = SessionIndexWriter(modelContainer: dependencies.modelContainer)
        let aggregator = SessionAggregator(readers: [reader])
        let initialStart = ContinuousClock.now
        let initialMetrics = try await aggregator.aggregate(
            writer: writer,
            modelContext: modelContext
        )
        let initialMilliseconds = milliseconds(since: initialStart)
        let indexedSessionCountAfterScan = try modelContext.fetchCount(
            FetchDescriptor<SessionIndex>()
        )
        guard indexedSessionCountAfterScan == manifest.sessionCount else {
            throw CocoaError(.fileWriteUnknown)
        }

        func exerciseNavigation(project: Project) async throws -> (
            transitions: Int,
            settingsOpened: Bool
        ) {
            var transitions = 0
            dependencies.selectedProjectStableId = project.stableId
            transitions += 1
            try await pause()
            for tab in DetailTab.allCases {
                NotificationCenter.default.post(
                    name: Notification.Name("DevHubSwitchTab"),
                    object: tab
                )
                transitions += 1
                try await pause()
            }
            dependencies.selectedGlobalDestination = .sessions
            transitions += 1
            try await pause()
            dependencies.selectedGlobalDestination = .projects
            transitions += 1
            try await pause()

            dependencies.requestedSettingsTab = .general
            let settingsOpened = NSApp.sendAction(
                Selector(("showSettingsWindow:")),
                to: nil,
                from: nil
            )
            try await pause(milliseconds: 120)
            for settingsTab in [SettingsTab.tools, .mcp, .plugins] {
                dependencies.requestedSettingsTab = settingsTab
                transitions += 1
                try await pause()
            }
            return (transitions, settingsOpened)
        }

        // Materialize one-time AppKit/SwiftUI resources before leak-oriented
        // cycle accounting. Warm-up samples still contribute to peak-memory
        // budgets; only first-use allocation is excluded from cycle growth.
        try writePhase("warmup")
        try await aggregator.aggregate(writer: writer, modelContext: modelContext)
        _ = try await exerciseNavigation(project: projects[0])

        var refreshDurations: [Int] = []
        var navigationTransitions = 0
        var settingsWindowOpenCount = 0

        for cycle in 0..<configuration.cycles {
            try writePhase(String(format: "cycle-%02d", cycle + 1))
            let refreshStart = ContinuousClock.now
            try await aggregator.aggregate(writer: writer, modelContext: modelContext)
            refreshDurations.append(milliseconds(since: refreshStart))

            let project = projects[cycle % projects.count]
            let navigation = try await exerciseNavigation(project: project)
            navigationTransitions += navigation.transitions
            if navigation.settingsOpened {
                settingsWindowOpenCount += 1
            }
        }

        try writePhase("recovery")
        if configuration.recoverySeconds > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(configuration.recoverySeconds) * 1_000_000_000
            )
        }
        try writeReport(PerformanceScenarioReport(
            schemaVersion: 1,
            succeeded: true,
            fixtureScale: manifest.scale,
            cycles: configuration.cycles,
            projectCount: manifest.projectCount,
            sessionCount: manifest.sessionCount,
            idleSeconds: configuration.idleSeconds,
            initialScanMilliseconds: initialMilliseconds,
            initialPreparationMilliseconds: initialMetrics.preparationMilliseconds,
            initialDiscoveryMilliseconds: initialMetrics.discoveryMilliseconds,
            initialProjectMatchingMilliseconds: initialMetrics.projectMatchingMilliseconds,
            initialWritingMilliseconds: initialMetrics.writingMilliseconds,
            initialWritePreparationMilliseconds: initialMetrics.writePreparationMilliseconds,
            initialWriteModelMutationMilliseconds: initialMetrics.writeModelMutationMilliseconds,
            initialWriteSaveMilliseconds: initialMetrics.writeSaveMilliseconds,
            initialWriteCacheMilliseconds: initialMetrics.writeCacheMilliseconds,
            repeatedRefreshMilliseconds: refreshDurations,
            navigationTransitions: navigationTransitions,
            settingsWindowOpenCount: settingsWindowOpenCount,
            recoverySeconds: configuration.recoverySeconds,
            failureCode: nil
        ))
        try writePhase("complete")
        exit(EXIT_SUCCESS)
    }

}
