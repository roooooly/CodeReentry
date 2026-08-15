import Foundation
import SwiftData

/// 从 SwiftData 抽取数据生成 BackupDocument（§8.4）。
/// 脱敏：Tool 密钥值不入档（只 key 名）；SessionIndex 不含 preview。
@ModelActor
public actor DataExporter {
    public static let currentSchemaVersion = 2

    public func export() async throws -> BackupDocument {
        let projects = try fetchProjects()
        let projectIdToStable = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0.stableId) })
        return BackupDocument(
            schemaVersion: Self.currentSchemaVersion,
            exportedAt: Date(),
            projects: projects.map(projectBackup),
            subscriptions: try fetchSubscriptions(projectIdToStable: projectIdToStable),
            platformAccounts: try fetchPlatformAccounts(),
            tools: try fetchTools(),
            sessionPreviews: try fetchSessionPreviews(),
            settings: try fetchSettings(),
            platformBindings: try fetchPlatformBindings()
        )
    }

    public nonisolated func fileName(for date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "devhub-backup-%04d%02d%02d.json",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func projectBackup(_ p: Project) -> BackupProject {
        BackupProject(stableId: p.stableId, name: p.name, path: p.path,
                      tags: p.tags, group: p.group, isPinned: p.isPinned,
                      status: p.status, version: p.version)
    }

    private func fetchProjects() throws -> [Project] {
        try modelContext.fetch(FetchDescriptor<Project>(sortBy: [SortDescriptor(\.name)]))
    }

    private func fetchSubscriptions(projectIdToStable: [UUID: String]) throws -> [BackupSubscription] {
        try modelContext.fetch(FetchDescriptor<Subscription>()).map { s in
            BackupSubscription(
                id: s.id, name: s.name, provider: s.provider, amount: s.amount,
                currency: s.currency, cycle: s.cycle.rawValue,
                nextRenewal: s.nextRenewal, reminderDaysBefore: s.reminderDaysBefore,
                notes: s.notes,
                projectStableId: s.project.flatMap { projectIdToStable[$0.id] },
                active: s.active
            )
        }
    }

    private func fetchTools() throws -> [BackupTool] {
        try modelContext.fetch(FetchDescriptor<Tool>()).map {
            BackupTool(id: $0.id, name: $0.name, kind: $0.kind.rawValue,
                       launchCommand: $0.launchCommand,
                       envVars: $0.envVars,
                       secretEnvKeys: $0.secretEnvKeys,
                       enabled: $0.enabled,
                       workingDirMode: $0.workingDirMode.rawValue,
                       customWorkingDir: $0.customWorkingDir,
                       injectMemory: $0.injectMemory,
                       injectionMode: $0.injectionMode.rawValue,
                       injectionArgs: $0.injectionArgs,
                       mcpServerRef: $0.mcpServerRef,
                       sortOrder: $0.sortOrder,
                       projectStableIds: $0.projects.map(\.stableId),
                       installCommand: $0.installCommand,
                       installMethod: $0.installMethod.rawValue,
                       detectPath: $0.detectPath,
                       downloadURL: $0.downloadURL)
        }
    }

    private func fetchPlatformAccounts() throws -> [BackupPlatformAccount] {
        try modelContext.fetch(FetchDescriptor<PlatformAccount>()).map {
            BackupPlatformAccount(id: $0.id, platform: $0.platform.rawValue,
                                  displayName: $0.displayName,
                                  loginUrl: $0.loginUrl)
        }
    }

    private func fetchPlatformBindings() throws -> [BackupPlatformBinding] {
        try modelContext.fetch(FetchDescriptor<ProjectPlatformBinding>()).compactMap { binding in
            guard let project = binding.project, let account = binding.account else { return nil }
            return BackupPlatformBinding(
                id: binding.id,
                projectStableId: project.stableId,
                accountId: account.id,
                accountPlatform: account.platform.rawValue,
                accountDisplayName: account.displayName,
                publishStatus: binding.publishStatus.rawValue,
                publishUrl: binding.publishUrl,
                publishNotes: binding.publishNotes,
                lastPublishedAt: binding.lastPublishedAt
            )
        }
    }

    private func fetchSessionPreviews() throws -> [BackupSessionPreview] {
        try modelContext.fetch(FetchDescriptor<SessionIndex>()).map { s in
            BackupSessionPreview(tool: s.tool, toolSessionId: s.toolSessionId,
                                 projectStableId: s.project?.stableId,
                                 startedAt: s.startedAt, updatedAt: s.updatedAt,
                                 messageCount: s.messageCount)
        }
    }

    private func fetchSettings() throws -> BackupAppSettings? {
        guard let s = try modelContext.fetch(FetchDescriptor<AppSettings>()).first else { return nil }
        return BackupAppSettings(projectsRoot: s.projectsRoot, enabledPlugins: s.enabledPlugins,
                                 theme: s.theme, sidebarWidth: s.sidebarWidth, locale: s.locale)
    }
}
