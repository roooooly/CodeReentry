import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("Isolated demo workspace")
@MainActor
struct DemoWorkspaceTests {
    @Test("--demo is the only argument that enables demo mode")
    func runtimeModeResolution() {
        #expect(AppRuntimeMode.resolve(arguments: ["CodeReentry"]) == .standard)
        #expect(AppRuntimeMode.resolve(arguments: ["CodeReentry", "--demo"]) == .demo)
        #expect(AppRuntimeMode.resolve(arguments: ["CodeReentry", "--build-only"]) == .standard)
    }

    @Test("app startup selects an in-memory store for demo mode")
    func demoStartupContainerIsInMemory() throws {
        let startup = DevHubApp.makeModelContainer(runtimeMode: .demo)
        let configuration = try #require(startup.container.configurations.first)

        #expect(configuration.isStoredInMemoryOnly)
        #expect(startup.warning == nil)
    }

    @Test("demo seed stays inside an in-memory container and synthetic temp root")
    func seedsSyntheticWorkspace() throws {
        let env = try makeEnvironment()
        defer { env.workspace.cleanup() }

        let projects = try env.container.mainContext.fetch(FetchDescriptor<Project>())
        let sessions = try env.container.mainContext.fetch(FetchDescriptor<SessionIndex>())
        let subscriptions = try env.container.mainContext.fetch(FetchDescriptor<Subscription>())

        #expect(projects.count == 3)
        #expect(sessions.count == 3)
        #expect(subscriptions.count == 2)
        #expect(projects.allSatisfy { $0.path.hasPrefix(env.workspace.rootURL.path + "/") })
        #expect(projects.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(sessions.allSatisfy { $0.sourcePath.hasPrefix(env.workspace.rootURL.path + "/") })
        #expect(env.dependencies.isDemoMode)
        #expect(env.dependencies.enabledDetailTabs == [.sessions, .memory])
        let checkout = try #require(projects.first { $0.stableId == "demo-checkout" })
        let recoveryTarget = ProjectsOverviewViewModel.cardData(for: checkout).latestSession
        #expect(recoveryTarget?.sessionId == "demo-checkout-sign-in")
        #expect(recoveryTarget?.readiness == .ready)
    }

    @Test("demo readers return only synthetic metadata and conversation bodies")
    func syntheticReadersPowerRefreshAndDetail() async throws {
        let env = try makeEnvironment()
        defer { env.workspace.cleanup() }

        let reader = try #require(env.dependencies.sessionReader(forToolId: "claude-code"))
        let discovered = try await reader.discover()
        let session = try #require(discovered.first)
        let detail = try await reader.load(session.toolSessionId)

        #expect(discovered.count == 1)
        #expect(session.sourcePath.hasPrefix(env.workspace.rootURL.path + "/"))
        #expect(detail.messages.count == 3)
        #expect(detail.messages.contains { $0.role == .tool })

        try await env.dependencies.runAggregation()
        #expect(try env.container.mainContext.fetchCount(FetchDescriptor<SessionIndex>()) == 3)
    }

    @Test("demo mode blocks external session launch before inspecting tool configuration")
    func blocksExternalResume() async throws {
        let env = try makeEnvironment()
        defer { env.workspace.cleanup() }

        await #expect(throws: SessionLaunchError.demoMode) {
            try await env.dependencies.resumeSession(
                toolId: "claude-code",
                sessionId: "demo-checkout-sign-in",
                projectPath: env.workspace.rootURL.appendingPathComponent("checkout").path
            )
        }
    }

    @Test("disabled usage scanner returns an empty in-memory snapshot")
    func demoUsageDoesNotReadLocalFiles() async {
        let scanner = UsageScanner(isEnabled: false)

        await scanner.refresh()

        #expect(scanner.snapshot?.totalTokens == 0)
        #expect(scanner.snapshot?.totalCostUSD == 0)
        #expect(scanner.codexRateLimit == nil)
        #expect(scanner.lastScannedAt != nil)
    }

    @Test("cleanup removes only the owned demo root and preferences domain")
    func cleanupIsScoped() throws {
        let env = try makeEnvironment()
        env.workspace.preferences.set("value", forKey: "demo-test")
        let root = env.workspace.rootURL
        let suite = env.workspace.preferencesSuiteName

        env.workspace.cleanup()

        #expect(!FileManager.default.fileExists(atPath: root.path))
        let reloaded = try #require(UserDefaults(suiteName: suite))
        #expect(reloaded.string(forKey: "demo-test") == nil)
    }

    private struct Environment {
        let container: ModelContainer
        let workspace: DemoWorkspace
        let dependencies: AppDependencies
    }

    private func makeEnvironment() throws -> Environment {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeReentry-Demo-Test-\(UUID().uuidString)", isDirectory: true)
        let suite = "CodeReentry.DemoWorkspaceTests.\(UUID().uuidString)"
        let workspace = try DemoWorkspace(rootURL: root, preferencesSuiteName: suite)
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let dependencies = AppDependencies(
            modelContainer: container,
            preferences: workspace.preferences,
            runtimeMode: .demo,
            sessionReaders: workspace.sessionReaders
        )
        try workspace.seed(into: container)
        return Environment(container: container, workspace: workspace, dependencies: dependencies)
    }
}
