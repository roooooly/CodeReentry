import Foundation
import SwiftData
import DevHubCore
import Darwin

private enum FixtureScale: String, CaseIterable {
    case small
    case medium
    case large

    var projectCount: Int {
        switch self {
        case .small: 5
        case .medium: 25
        case .large: 100
        }
    }

    var sessionsPerProject: Int {
        switch self {
        case .small: 20
        case .medium: 100
        case .large: 200
        }
    }

    var sessionCount: Int { projectCount * sessionsPerProject }
}

private enum FixtureIndexState: String {
    case full
    case empty
}

private enum FixtureToolError: LocalizedError {
    case usage
    case invalidScale(String)
    case profileAlreadyContainsStore
    case missingStore
    case countMismatch(entity: String, expected: Int, actual: Int)

    var errorDescription: String? {
        switch self {
        case .usage:
            return "Usage: DevHubFixtureTool <create|verify> --profile /isolated/path --scale <small|medium|large> [--index-state <full|empty>]"
        case .invalidScale(let value):
            return "Unsupported scale: \(value)"
        case .profileAlreadyContainsStore:
            return "The isolated profile already contains a DevHub store; refusing to overwrite it."
        case .missingStore:
            return "The isolated profile does not contain a DevHub store."
        case .countMismatch(let entity, let expected, let actual):
            return "Fixture \(entity) count mismatch: expected \(expected), found \(actual)."
        }
    }
}

private struct FixtureArguments {
    enum Command: String { case create, verify }

    let command: Command
    let profile: URL
    let scale: FixtureScale
    let indexState: FixtureIndexState

    init(arguments: [String]) throws {
        guard arguments.count >= 2,
              let command = Command(rawValue: arguments[1]) else {
            throw FixtureToolError.usage
        }
        var profilePath: String?
        var scaleValue: String?
        var indexStateValue = FixtureIndexState.full.rawValue
        var index = 2
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            guard index < arguments.count else { throw FixtureToolError.usage }
            let value = arguments[index]
            index += 1
            switch option {
            case "--profile": profilePath = value
            case "--scale": scaleValue = value
            case "--index-state": indexStateValue = value
            default: throw FixtureToolError.usage
            }
        }
        guard let profilePath, !profilePath.isEmpty, let scaleValue else {
            throw FixtureToolError.usage
        }
        guard let scale = FixtureScale(rawValue: scaleValue) else {
            throw FixtureToolError.invalidScale(scaleValue)
        }
        guard let indexState = FixtureIndexState(rawValue: indexStateValue) else {
            throw FixtureToolError.usage
        }
        self.command = command
        self.profile = URL(fileURLWithPath: profilePath, isDirectory: true).standardizedFileURL
        self.scale = scale
        self.indexState = indexState
    }
}

@main
private struct DevHubFixtureTool {
    @MainActor
    static func main() {
        do {
            let arguments = try FixtureArguments(arguments: CommandLine.arguments)
            switch arguments.command {
            case .create:
                try createFixture(
                    profile: arguments.profile,
                    scale: arguments.scale,
                    indexState: arguments.indexState
                )
                try verifyFixture(
                    profile: arguments.profile,
                    scale: arguments.scale,
                    indexState: arguments.indexState
                )
            case .verify:
                try verifyFixture(
                    profile: arguments.profile,
                    scale: arguments.scale,
                    indexState: arguments.indexState
                )
            }
        } catch {
            let message = "error: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(64)
        }
    }

    private static func storeURL(in profile: URL) -> URL {
        profile
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("DevHub", isDirectory: true)
            .appendingPathComponent("DevHub.store")
    }

    private static func fixtureRoot(in profile: URL) -> URL {
        profile.appendingPathComponent("SyntheticFixtures", isDirectory: true)
    }

    @MainActor
    private static func container(at store: URL) throws -> ModelContainer {
        let schema = Schema(DevHubSchemaV1.models)
        let configuration = ModelConfiguration(
            schema: schema,
            url: store,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainerFactory.makeContainer(configurations: [configuration])
    }

    @MainActor
    private static func createFixture(
        profile: URL,
        scale: FixtureScale,
        indexState: FixtureIndexState
    ) throws {
        let fileManager = FileManager.default
        let store = storeURL(in: profile)
        let storeDirectory = store.deletingLastPathComponent()
        let root = fixtureRoot(in: profile)
        let projectsRoot = root.appendingPathComponent("Projects", isDirectory: true)
        let sourcesRoot = root.appendingPathComponent("SessionSources", isDirectory: true)

        let existingStoreFiles = ((try? fileManager.contentsOfDirectory(
            at: storeDirectory,
            includingPropertiesForKeys: nil
        )) ?? []).contains { $0.lastPathComponent.hasPrefix("DevHub.store") }
        guard !existingStoreFiles else { throw FixtureToolError.profileAlreadyContainsStore }

        try fileManager.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sourcesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: storeDirectory, withIntermediateDirectories: true)

        let tools = ["claude-code", "codex", "zcode", "opencode", "kimi"]
        var sourceFiles: [String: URL] = [:]
        for tool in tools {
            let source = sourcesRoot.appendingPathComponent("\(tool)-synthetic-session.jsonl")
            let line = "{\"fixture\":true,\"tool\":\"\(tool)\"}\n"
            try line.write(to: source, atomically: true, encoding: .utf8)
            sourceFiles[tool] = source
        }

        let container = try container(at: store)
        let context = container.mainContext
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        for projectIndex in 0..<scale.projectCount {
            let projectNumber = projectIndex + 1
            let projectDirectory = projectsRoot.appendingPathComponent(
                String(format: "project-%03d", projectNumber),
                isDirectory: true
            )
            try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
            let project = Project(
                stableId: String(format: "fixture-project-%03d", projectNumber),
                name: String(format: "Fixture Project %03d", projectNumber),
                path: projectDirectory.path,
                icon: "shippingbox.fill",
                color: "blue",
                createdAt: baseDate.addingTimeInterval(TimeInterval(projectIndex * 60)),
                lastOpenedAt: baseDate.addingTimeInterval(TimeInterval(projectIndex * 120)),
                isPinned: projectIndex < min(5, scale.projectCount),
                group: "Fixture Group \(projectIndex % 5 + 1)",
                tags: ["synthetic", scale.rawValue]
            )
            context.insert(project)

            let memory = MemoryStore(projectRoot: projectDirectory)
            try memory.writeContext(
                "# Synthetic project context\n- Fixture scale: \(scale.rawValue)\n- Project slot: p\(projectNumber)\n"
            )

            if indexState == .full {
                for sessionOffset in 0..<scale.sessionsPerProject {
                    let globalIndex = projectIndex * scale.sessionsPerProject + sessionOffset
                    let tool = tools[globalIndex % tools.count]
                    let updatedAt = baseDate.addingTimeInterval(TimeInterval(globalIndex * 30))
                    let session = SessionIndex(
                        tool: tool,
                        toolSessionId: String(format: "fixture-%@-%06d", tool, globalIndex + 1),
                        sourcePath: sourceFiles[tool]!.path,
                        projectCwd: projectDirectory.path,
                        startedAt: updatedAt.addingTimeInterval(-600),
                        updatedAt: updatedAt,
                        messageCount: globalIndex % 40 + 1,
                        title: "Synthetic recovery session \(globalIndex + 1)",
                        preview: "Deterministic fixture preview without project or conversation content.",
                        indexedAt: updatedAt,
                        project: project
                    )
                    context.insert(session)
                }
            }
        }
        try context.save()
        _ = try DefaultToolCatalog.seedIfNeeded(in: context)
        let manifest = PerformanceFixtureManifest(
            scale: scale.rawValue,
            projectCount: scale.projectCount,
            sessionsPerProject: scale.sessionsPerProject,
            initialIndexState: indexState.rawValue
        )
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(
            to: root.appendingPathComponent(PerformanceFixtureManifest.fileName),
            options: .atomic
        )
        let indexedSessions = indexState == .full ? scale.sessionCount : 0
        print("Created \(scale.rawValue) fixture: \(scale.projectCount) projects, \(scale.sessionCount) synthetic sessions, \(indexedSessions) preindexed, 6 tools.")
    }

    @MainActor
    private static func verifyFixture(
        profile: URL,
        scale: FixtureScale,
        indexState: FixtureIndexState
    ) throws {
        let store = storeURL(in: profile)
        guard FileManager.default.fileExists(atPath: store.path) else {
            throw FixtureToolError.missingStore
        }
        let container = try container(at: store)
        let context = container.mainContext
        let projectCount = try context.fetchCount(FetchDescriptor<Project>())
        let sessionCount = try context.fetchCount(FetchDescriptor<SessionIndex>())
        let toolCount = try context.fetchCount(FetchDescriptor<Tool>())
        let manifestURL = fixtureRoot(in: profile)
            .appendingPathComponent(PerformanceFixtureManifest.fileName)
        let manifest = try JSONDecoder().decode(
            PerformanceFixtureManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == PerformanceFixtureManifest.schemaVersion,
              manifest.scale == scale.rawValue,
              manifest.projectCount == scale.projectCount,
              manifest.sessionsPerProject == scale.sessionsPerProject,
              manifest.initialIndexState == indexState.rawValue else {
            throw FixtureToolError.countMismatch(
                entity: "manifest session", expected: scale.sessionCount,
                actual: manifest.sessionCount
            )
        }
        guard projectCount == scale.projectCount else {
            throw FixtureToolError.countMismatch(
                entity: "project", expected: scale.projectCount, actual: projectCount
            )
        }
        let expectedIndexedSessions = indexState == .full ? scale.sessionCount : 0
        guard sessionCount == expectedIndexedSessions else {
            throw FixtureToolError.countMismatch(
                entity: "session", expected: expectedIndexedSessions, actual: sessionCount
            )
        }
        guard toolCount == 6 else {
            throw FixtureToolError.countMismatch(entity: "tool", expected: 6, actual: toolCount)
        }
        print("Verified \(scale.rawValue) fixture: \(projectCount) projects, \(sessionCount) preindexed sessions, \(toolCount) tools.")
    }
}
