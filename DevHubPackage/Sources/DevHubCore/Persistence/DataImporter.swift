import Foundation
import SwiftData

public enum DataImportError: Error, Equatable, LocalizedError {
    case unsupportedSchema(found: Int, expected: Int)
    case invalidImportReport
    case missingManualPath(stableId: String)
    case invalidProjectDirectory(stableId: String, path: String)
    case conflictingStableId(expected: String, found: String, path: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let found, let expected):
            return String(localized: "不支持备份格式 v\(found)，当前最高支持 v\(expected)。")
        case .invalidImportReport:
            return String(localized: "导入规划与备份内容不一致，请重新选择备份文件。")
        case .missingManualPath(let stableId):
            return String(localized: "项目 \(stableId) 尚未指定恢复目录。")
        case .invalidProjectDirectory(let stableId, let path):
            return String(localized: "项目 \(stableId) 的恢复目录不存在或不是文件夹：\(path)")
        case .conflictingStableId(let expected, let found, let path):
            return String(localized: "目录 \(path) 已属于另一个项目（\(found)），不能恢复为 \(expected)。")
        }
    }
}

public struct ImportReport: Sendable, Equatable {
    public var relocations: [RelocationResult]
    public var projectsPendingManual: [String]  // 缺失路径的 stableId 列表

    public init(relocations: [RelocationResult], projectsPendingManual: [String]) {
        self.relocations = relocations
        self.projectsPendingManual = projectsPendingManual
    }
}

public enum DataImportMode: String, Sendable, Equatable, CaseIterable {
    case merge
    case replace
}

/// 导入 BackupDocument（§8.4）。两步：planImport（路径重新定位）→ applyImport（用户补全后写入）。
/// pathRelocator 通过构造后属性注入（@ModelActor 合成的 init(modelContainer:) 不能加额外参数）。
@ModelActor
public actor DataImporter {
    public var pathRelocator: PathRelocator = PathRelocator()

    /// 第 1 步：规划导入，检查所有路径，返回需手动处理的 stableId。
    public func planImport(document: BackupDocument, searchRoots: [String]) async throws -> ImportReport {
        guard (1...DataExporter.currentSchemaVersion).contains(document.schemaVersion) else {
            throw DataImportError.unsupportedSchema(
                found: document.schemaVersion, expected: DataExporter.currentSchemaVersion)
        }
        var relocations: [RelocationResult] = []
        var pending: [String] = []
        for p in document.projects {
            let r = pathRelocator.resolve(stableId: p.stableId, originalPath: p.path, searchRoots: searchRoots)
            relocations.append(r)
            if case .missing(let sid) = r { pending.append(sid) }
        }
        return ImportReport(relocations: relocations, projectsPendingManual: pending)
    }

    /// 第 2 步：用户补全路径后实际写入。
    public func applyImport(
        document: BackupDocument,
        report: ImportReport,
        manualPaths: [String: String],
        mode: DataImportMode = .merge
    ) async throws {
        guard report.relocations.count == document.projects.count else {
            throw DataImportError.invalidImportReport
        }

        // 在开始写 SwiftData 前一次性验证所有路径。缺失项目必须由用户明确指定；
        // 每个有效目录都补齐 stableId 锚点，已有但冲突的锚点绝不覆盖。
        var resolvedPaths: [String] = []
        for (index, project) in document.projects.enumerated() {
            let resolved: String
            switch report.relocations[index] {
            case .resolved(let path):
                resolved = path
            case .missing(let stableId):
                guard stableId == project.stableId else {
                    throw DataImportError.invalidImportReport
                }
                guard let path = manualPaths[stableId]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty else {
                    throw DataImportError.missingManualPath(stableId: stableId)
                }
                resolved = path
            }
            let standardized = (resolved as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw DataImportError.invalidProjectDirectory(
                    stableId: project.stableId,
                    path: standardized
                )
            }
            let root = URL(fileURLWithPath: standardized, isDirectory: true)
            let anchoredId = try PathLocator.ensureDevHub(at: root, stableId: project.stableId)
            guard anchoredId == project.stableId else {
                throw DataImportError.conflictingStableId(
                    expected: project.stableId,
                    found: anchoredId,
                    path: standardized
                )
            }
            resolvedPaths.append((standardized as NSString).standardizingPath)
        }

        // replace 会在同一次 SwiftData save 中移除现有数据；路径与 stableId 已在上方
        // 全部验证，因此不会因一个未定位项目先清空用户数据。
        if mode == .replace {
            try modelContext.fetch(FetchDescriptor<ProjectPlatformBinding>()).forEach(modelContext.delete)
            try modelContext.fetch(FetchDescriptor<SessionIndex>()).forEach(modelContext.delete)
            try modelContext.fetch(FetchDescriptor<Subscription>()).forEach(modelContext.delete)
            try modelContext.fetch(FetchDescriptor<Tool>()).forEach(modelContext.delete)
            try modelContext.fetch(FetchDescriptor<PlatformAccount>()).forEach(modelContext.delete)
            try modelContext.fetch(FetchDescriptor<Project>()).forEach(modelContext.delete)
            try modelContext.fetch(FetchDescriptor<AppSettings>()).forEach(modelContext.delete)
        }

        // Merge 语义：按持久身份更新，缺失才插入；重复导入同一备份必须幂等。
        var stableIdToProject: [String: Project] = mode == .merge
            ? Dictionary(uniqueKeysWithValues:
                try modelContext.fetch(FetchDescriptor<Project>()).map { ($0.stableId, $0) })
            : [:]
        for (i, p) in document.projects.enumerated() {
            let resolved = resolvedPaths[i]
            let proj: Project
            if let existing = stableIdToProject[p.stableId] {
                proj = existing
                proj.name = p.name; proj.path = resolved; proj.tags = p.tags
                proj.group = p.group; proj.isPinned = p.isPinned
                if let s = p.status { proj.status = s }
                if let v = p.version { proj.version = v }
            } else {
                proj = Project(stableId: p.stableId, name: p.name, path: resolved,
                               isPinned: p.isPinned, group: p.group, tags: p.tags,
                               status: ProjectStatus(rawValue: p.status ?? "") ?? .active,
                               version: p.version ?? "")
                modelContext.insert(proj)
            }
            stableIdToProject[p.stableId] = proj
        }

        var accounts = mode == .merge
            ? try modelContext.fetch(FetchDescriptor<PlatformAccount>())
            : []
        var accountById = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        for item in document.platformAccounts {
            let platform = Platform(rawValue: item.platform) ?? .twitter
            let existingAccount = item.id.flatMap { accountById[$0] }
                ?? accounts.first { $0.platformRaw == item.platform && $0.displayName == item.displayName }
            let account = existingAccount ?? PlatformAccount(
                id: item.id ?? UUID(), platform: platform,
                displayName: item.displayName, loginUrl: item.loginUrl
            )
            account.platform = platform
            account.displayName = item.displayName
            account.loginUrl = item.loginUrl
            if existingAccount == nil { modelContext.insert(account); accounts.append(account) }
            accountById[account.id] = account
        }

        var tools = mode == .merge ? try modelContext.fetch(FetchDescriptor<Tool>()) : []
        for item in document.tools {
            let existing = item.id.flatMap { id in tools.first { $0.id == id } }
                ?? tools.first { $0.name.caseInsensitiveCompare(item.name) == .orderedSame }
            let kind = ToolKind(rawValue: item.kind) ?? .cli
            let inferredMode: InjectionMode = {
                if let raw = item.injectionMode, let mode = InjectionMode(rawValue: raw) { return mode }
                if item.name.lowercased().contains("codex") || item.name.lowercased().contains("zcode") {
                    return .positionalArg
                }
                return kind == .cli ? .cliFlag : .clipboard
            }()
            let tool = existing ?? Tool(
                id: item.id ?? UUID(), name: item.name, kind: kind,
                launchCommand: item.launchCommand,
                workingDirMode: WorkingDirMode(rawValue: item.workingDirMode ?? "") ?? .projectRoot,
                customWorkingDir: item.customWorkingDir,
                injectMemory: item.injectMemory ?? (kind == .cli),
                injectionMode: inferredMode,
                injectionArgs: item.injectionArgs,
                envVars: item.envVars, secretEnvKeys: item.secretEnvKeys,
                mcpServerRef: item.mcpServerRef, enabled: item.enabled,
                sortOrder: item.sortOrder ?? tools.count,
                installCommand: item.installCommand,
                installMethod: InstallMethod(rawValue: item.installMethod ?? "") ?? .manual,
                detectPath: item.detectPath,
                downloadURL: item.downloadURL
            )
            tool.name = item.name; tool.kind = kind; tool.launchCommand = item.launchCommand
            tool.workingDirMode = WorkingDirMode(rawValue: item.workingDirMode ?? "") ?? .projectRoot
            tool.customWorkingDir = item.customWorkingDir
            tool.injectMemory = item.injectMemory ?? (kind == .cli)
            tool.injectionMode = inferredMode; tool.injectionArgs = item.injectionArgs
            tool.envVars = item.envVars; tool.secretEnvKeys = item.secretEnvKeys
            tool.mcpServerRef = item.mcpServerRef; tool.enabled = item.enabled
            tool.sortOrder = item.sortOrder ?? tool.sortOrder
            tool.installCommand = item.installCommand
            tool.installMethod = InstallMethod(rawValue: item.installMethod ?? "") ?? .manual
            tool.detectPath = item.detectPath
            tool.downloadURL = item.downloadURL
            if let ids = item.projectStableIds {
                tool.projects = ids.compactMap { stableIdToProject[$0] }
            }
            if existing == nil { modelContext.insert(tool); tools.append(tool) }
        }

        var subscriptions = mode == .merge ? try modelContext.fetch(FetchDescriptor<Subscription>()) : []
        for s in document.subscriptions {
            let cycle = SubscriptionCycle(rawValue: s.cycle) ?? .monthly
            let project = s.projectStableId.flatMap { stableIdToProject[$0] }
            let existingSubscription = s.id.flatMap { id in subscriptions.first { $0.id == id } }
                ?? subscriptions.first {
                    $0.name == s.name && $0.provider == s.provider && $0.project?.stableId == s.projectStableId
                }
            let sub = existingSubscription ?? Subscription(
                id: s.id ?? UUID(), name: s.name, provider: s.provider,
                amount: s.amount, currency: s.currency, cycle: cycle,
                nextRenewal: s.nextRenewal, notes: s.notes,
                reminderDaysBefore: s.reminderDaysBefore, active: s.active ?? true
            )
            sub.name = s.name; sub.provider = s.provider; sub.amount = s.amount
            sub.currency = s.currency; sub.cycle = cycle; sub.nextRenewal = s.nextRenewal
            sub.notes = s.notes; sub.reminderDaysBefore = s.reminderDaysBefore
            sub.active = s.active ?? true
            sub.project = project
            if existingSubscription == nil { modelContext.insert(sub); subscriptions.append(sub) }
        }

        var bindings = mode == .merge
            ? try modelContext.fetch(FetchDescriptor<ProjectPlatformBinding>())
            : []
        for item in document.platformBindings ?? [] {
            guard let project = stableIdToProject[item.projectStableId] else { continue }
            let account = item.accountId.flatMap { accountById[$0] }
                ?? accounts.first {
                    $0.platformRaw == item.accountPlatform && $0.displayName == item.accountDisplayName
                }
            guard let account else { continue }
            let existingBinding = item.id.flatMap { id in bindings.first { $0.id == id } }
                ?? bindings.first { $0.project?.stableId == item.projectStableId && $0.account?.id == account.id }
            let binding = existingBinding ?? ProjectPlatformBinding(
                id: item.id ?? UUID(), project: project, account: account
            )
            binding.project = project; binding.account = account
            binding.publishStatus = PublishStatus(rawValue: item.publishStatus) ?? .draft
            binding.publishUrl = item.publishUrl; binding.publishNotes = item.publishNotes
            binding.lastPublishedAt = item.lastPublishedAt
            if existingBinding == nil { modelContext.insert(binding); bindings.append(binding) }
        }

        var sessions = mode == .merge ? try modelContext.fetch(FetchDescriptor<SessionIndex>()) : []
        for item in document.sessionPreviews {
            let identity = "\(item.tool):\(item.toolSessionId)"
            let project = item.projectStableId.flatMap { stableIdToProject[$0] }
            if let existing = sessions.first(where: { $0.identityKey == identity }) {
                existing.startedAt = item.startedAt; existing.updatedAt = item.updatedAt
                existing.messageCount = item.messageCount; existing.project = project
                if existing.projectCwd.isEmpty { existing.projectCwd = project?.path ?? "" }
            } else {
                let session = SessionIndex(
                    tool: item.tool, toolSessionId: item.toolSessionId,
                    sourcePath: "", projectCwd: project?.path ?? "",
                    startedAt: item.startedAt, updatedAt: item.updatedAt,
                    messageCount: item.messageCount, title: nil, preview: "", project: project
                )
                modelContext.insert(session); sessions.append(session)
            }
        }
        if let settings = document.settings {
            let existing = mode == .merge
                ? try modelContext.fetch(FetchDescriptor<AppSettings>()).first
                : nil
            let target = existing ?? AppSettings(id: AppSettings.singletonId)
            target.projectsRoot = settings.projectsRoot
            target.enabledPlugins = settings.enabledPlugins
            target.theme = settings.theme
            target.sidebarWidth = settings.sidebarWidth
            target.locale = settings.locale
            modelContext.insert(target)
        }
        try modelContext.save()
    }
}

public extension DataImporter {
    /// 工厂：构造并注入 pathRelocator（绕过 @ModelActor init 限制）。
    static func make(modelContainer: ModelContainer, pathRelocator: PathRelocator) async -> DataImporter {
        let importer = DataImporter(modelContainer: modelContainer)
        await importer.setPathRelocator(pathRelocator)
        return importer
    }

    func setPathRelocator(_ r: PathRelocator) { pathRelocator = r }
}
