import Foundation
import SwiftData
import DevHubCore

enum AppRuntimeMode: Equatable, Sendable {
    case standard
    case demo

    static func resolve(arguments: [String]) -> Self {
        arguments.contains("--demo") ? .demo : .standard
    }
}

/// An isolated, disposable workspace for evaluating the recovery flow without
/// exposing any real project or session data. The SwiftData store is created by
/// the caller in memory; this object owns only synthetic files under a unique
/// temporary directory and a separate UserDefaults suite.
@MainActor
final class DemoWorkspace {
    let rootURL: URL
    let preferences: UserDefaults
    let preferencesSuiteName: String

    private let fileManager: FileManager
    private let records: [DemoSessionRecord]

    init(
        rootURL: URL? = nil,
        preferencesSuiteName: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("CodeReentry-Demo-\(UUID().uuidString)", isDirectory: true)
        self.preferencesSuiteName = preferencesSuiteName
            ?? "io.github.roooooly.devhub.demo.\(UUID().uuidString)"
        guard let preferences = UserDefaults(suiteName: self.preferencesSuiteName) else {
            throw DemoWorkspaceError.preferencesUnavailable
        }
        self.preferences = preferences
        preferences.removePersistentDomain(forName: self.preferencesSuiteName)
        try fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        self.records = Self.makeRecords(rootURL: self.rootURL)
    }

    var sessionReaders: [any SessionReader] {
        let tools = Array(Set(records.map(\.tool))).sorted()
        return tools.map { tool in
            DemoSessionReader(toolId: tool, records: records.filter { $0.tool == tool })
        }
    }

    func seed(into container: ModelContainer) throws {
        let context = container.mainContext
        let now = Date()
        let projectSpecs: [(key: String, name: String, color: String, version: String, status: ProjectStatus)] = [
            ("checkout", "CheckoutApp", "#3B82F6", "1.4.0", .active),
            ("api", "APIService", "#1F7A67", "2.1.0", .active),
            ("tools", "DeveloperTools", "#7D1727", "0.9.0", .paused)
        ]
        var projectsByKey: [String: Project] = [:]

        for (index, spec) in projectSpecs.enumerated() {
            let path = rootURL.appendingPathComponent(spec.key, isDirectory: true)
            try fileManager.createDirectory(at: path, withIntermediateDirectories: true)
            try Data("{}\n".utf8).write(to: path.appendingPathComponent("package.json"))
            let project = Project(
                stableId: "demo-\(spec.key)",
                name: spec.name,
                path: path.path,
                icon: index == 0 ? "cart.fill" : index == 1 ? "server.rack" : "hammer.fill",
                color: spec.color,
                createdAt: now.addingTimeInterval(TimeInterval(-86_400 * (index + 5))),
                lastOpenedAt: now.addingTimeInterval(TimeInterval(-1_800 * (index + 1))),
                isPinned: index < 2,
                group: index < 2 ? "Active" : "Later",
                tags: index == 0 ? ["swift", "payments"] : index == 1 ? ["backend"] : ["tooling"],
                status: spec.status,
                version: spec.version
            )
            context.insert(project)
            projectsByKey[spec.key] = project

            let memory = MemoryStore(projectRoot: path)
            try memory.writeContext(Self.contextMarkdown(for: spec.name))
        }

        let tools = try context.fetch(FetchDescriptor<Tool>())
        for tool in tools {
            // Readiness checks should show the complete recovery affordance in
            // demo mode, while AppDependencies still blocks every real launch.
            tool.launchCommand = "/usr/bin/true"
            tool.detectPath = "/usr/bin/true"
            tool.envVars = [:]
            tool.secretEnvKeys = []
        }
        for record in records {
            guard let project = projectsByKey[record.projectKey] else { continue }
            let session = SessionIndex(
                tool: record.tool,
                toolSessionId: record.sessionId,
                sourcePath: record.sourcePath,
                projectCwd: project.path,
                startedAt: record.startedAt,
                updatedAt: record.updatedAt,
                messageCount: record.messages.count,
                title: record.title,
                preview: record.preview,
                project: project
            )
            context.insert(session)
            if let tool = tools.first(where: {
                ToolIdentifierResolver.matches($0, sessionToolIdentifier: record.tool)
            }), !tool.projects.contains(where: { $0.id == project.id }) {
                tool.projects.append(project)
            }
        }

        if let checkout = projectsByKey["checkout"] {
            let subscription = Subscription(
                name: "AI coding plan",
                provider: "Example Provider",
                amount: 20,
                currency: "USD",
                cycle: .monthly,
                nextRenewal: now.addingTimeInterval(86_400 * 12),
                notes: "Synthetic demo subscription"
            )
            subscription.project = checkout
            context.insert(subscription)
        }
        if let api = projectsByKey["api"] {
            let subscription = Subscription(
                name: "Test hosting",
                provider: "Example Cloud",
                amount: 12,
                currency: "USD",
                cycle: .monthly,
                nextRenewal: now.addingTimeInterval(86_400 * 18),
                notes: "Synthetic demo subscription"
            )
            subscription.project = api
            context.insert(subscription)
        }
        try context.save()
    }

    func cleanup() {
        preferences.removePersistentDomain(forName: preferencesSuiteName)
        guard rootURL.path != "/",
              rootURL != fileManager.homeDirectoryForCurrentUser,
              rootURL.lastPathComponent.hasPrefix("CodeReentry-Demo-") else { return }
        try? fileManager.removeItem(at: rootURL)
    }

    private static func contextMarkdown(for projectName: String) -> String {
        """
        # \(projectName) context

        - Keep public interfaces stable while resuming unfinished work.
        - Run focused tests before broad suites.
        - This file contains synthetic demo content only.
        """
    }

    private static func makeRecords(rootURL: URL) -> [DemoSessionRecord] {
        let now = Date()
        return [
            DemoSessionRecord(
                projectKey: "checkout",
                tool: "claude-code",
                sessionId: "demo-checkout-sign-in",
                sourcePath: rootURL.appendingPathComponent("sessions/checkout.jsonl").path,
                startedAt: now.addingTimeInterval(-4_200),
                updatedAt: now.addingTimeInterval(-2_700),
                title: "Repair the sign-in flow",
                preview: "Keep the existing session API while fixing the invalid transition.",
                messages: [
                    SessionMessage(role: .user, content: "Repair the sign-in error without changing the session API.", timestamp: now.addingTimeInterval(-4_200)),
                    SessionMessage(role: .assistant, content: "I found the failing state transition and kept the public API intact.", timestamp: now.addingTimeInterval(-3_000)),
                    SessionMessage(role: .tool, content: #"{"path":"Sources/LoginView.swift"}"#, timestamp: now.addingTimeInterval(-2_900), toolName: "edit", toolInput: #"{"path":"Sources/LoginView.swift"}"#)
                ]
            ),
            DemoSessionRecord(
                projectKey: "api",
                tool: "codex",
                sessionId: "demo-api-pagination",
                sourcePath: rootURL.appendingPathComponent("sessions/api.jsonl").path,
                startedAt: now.addingTimeInterval(-86_400),
                updatedAt: now.addingTimeInterval(-82_800),
                title: "Bound the events endpoint",
                preview: "Add cursor pagination without changing the response envelope.",
                messages: [
                    SessionMessage(role: .user, content: "Add cursor pagination and preserve the response envelope.", timestamp: now.addingTimeInterval(-86_400)),
                    SessionMessage(role: .assistant, content: "The endpoint now validates cursors and caps page size at 100.", timestamp: now.addingTimeInterval(-82_800))
                ]
            ),
            DemoSessionRecord(
                projectKey: "tools",
                tool: "gemini-cli",
                sessionId: "demo-tools-release",
                sourcePath: rootURL.appendingPathComponent("sessions/tools.jsonl").path,
                startedAt: now.addingTimeInterval(-604_800),
                updatedAt: now.addingTimeInterval(-600_000),
                title: "Verify the release checklist",
                preview: "Re-run privacy and packaging checks before tagging.",
                messages: [
                    SessionMessage(role: .user, content: "Verify the release checklist and report failed gates.", timestamp: now.addingTimeInterval(-604_800)),
                    SessionMessage(role: .assistant, content: "Privacy and source-build checks pass; signing is still pending.", timestamp: now.addingTimeInterval(-600_000))
                ]
            )
        ]
    }
}

private struct DemoSessionRecord: Sendable {
    let projectKey: String
    let tool: String
    let sessionId: String
    let sourcePath: String
    let startedAt: Date
    let updatedAt: Date
    let title: String
    let preview: String
    let messages: [SessionMessage]

    var discovered: DiscoveredSession {
        DiscoveredSession(
            tool: tool,
            toolSessionId: sessionId,
            sourcePath: sourcePath,
            projectCwd: URL(fileURLWithPath: sourcePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(projectKey).path,
            startedAt: startedAt,
            updatedAt: updatedAt,
            messageCount: messages.count,
            title: title,
            preview: preview
        )
    }

    var detail: SessionDetail {
        SessionDetail(
            tool: tool,
            toolSessionId: sessionId,
            cwd: discovered.projectCwd,
            startedAt: startedAt,
            messages: messages
        )
    }
}

private struct DemoSessionReader: SessionReader {
    let toolId: String
    let records: [DemoSessionRecord]

    func discover() async throws -> [DiscoveredSession] {
        records.map(\.discovered)
    }

    func load(_ id: String) async throws -> SessionDetail {
        guard let record = records.first(where: { $0.sessionId == id }) else {
            throw DemoWorkspaceError.sessionNotFound
        }
        return record.detail
    }
}

enum DemoWorkspaceError: LocalizedError {
    case preferencesUnavailable
    case sessionNotFound

    var errorDescription: String? {
        switch self {
        case .preferencesUnavailable:
            return "Unable to create isolated demo preferences."
        case .sessionNotFound:
            return "Synthetic demo session not found."
        }
    }
}
