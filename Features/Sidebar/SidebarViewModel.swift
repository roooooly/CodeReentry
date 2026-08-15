import Foundation
import SwiftData
import OSLog
import DevHubCore

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "sidebar")

/// 一个活跃分组（自定义 group 名）及其项目
struct SidebarActiveGroup: Identifiable {
    let name: String
    let projects: [Project]
    var id: String { name }
}

struct SidebarProjectEditDraft: Identifiable, Equatable {
    let id: UUID
    let name: String
    var group: String
    var tags: String
}

struct SidebarProjectRemoval: Identifiable, Equatable {
    let id: UUID
    let stableId: String
    let name: String
}

@Observable
@MainActor
final class SidebarViewModel {
    var pinnedProjects: [Project] = []
    var activeGroups: [SidebarActiveGroup] = []
    var archivedProjects: [Project] = []
    var missingProjectIds: Set<UUID> = []

    /// 是否显示"+ 项目"的注册确认对话框
    var presentingAddDialog: Bool = false
    var pendingDropPath: String?
    var editDraft: SidebarProjectEditDraft?
    var pendingRemoval: SidebarProjectRemoval?
    var operationError: String?

    static let defaultGroupName = String(localized: "项目")
    static let archiveGroupName = "Archive"
    static let projectsChangedNotification = Notification.Name("DevHubProjectsChanged")

    /// 从 ModelContext 加载并分组。每次 SwiftData 变更后调用。
    func loadProjects(from ctx: ModelContext) {
        let descriptor = FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        guard let all = try? ctx.fetch(descriptor) else {
            logger.error("加载项目失败")
            return
        }

        missingProjectIds = Set(
            all.lazy
                .filter { ProjectPathAvailability.evaluate(path: $0.path) == .missing }
                .map(\.id)
        )

        pinnedProjects = all.filter { $0.isPinned }
        archivedProjects = all.filter { $0.group == Self.archiveGroupName && !$0.isPinned }

        // 活跃：非 pinned、非 Archive；按 group 名聚合，nil → 默认组
        let actives = all.filter { !$0.isPinned && $0.group != Self.archiveGroupName }
        var bucket: [String: [Project]] = [:]
        var order: [String] = []
        for p in actives {
            let g = p.group ?? Self.defaultGroupName
            if bucket[g] == nil { order.append(g) }
            bucket[g, default: []].append(p)
        }
        // 默认组排到活跃组最后
        if let defIdx = order.firstIndex(of: Self.defaultGroupName) {
            order.remove(at: defIdx)
            order.append(Self.defaultGroupName)
        }
        activeGroups = order.map { SidebarActiveGroup(name: $0, projects: bucket[$0] ?? []) }
    }

    /// 拖拽文件夹注册：名称由路径末段推导，stableId 生成新的；委托 Core ProjectRegistry。
    @discardableResult
    func registerDroppedFolder(at path: String, deps: AppDependencies, ctx: ModelContext) throws -> Project {
        logger.info("注册拖入文件夹: \(path, privacy: .public)")
        let standard = (path as NSString).standardizingPath
        let name = (standard as NSString).lastPathComponent
        let stableId = UUID().uuidString
        let project = try deps.projectRegistry(in: ctx).register(
            name: name, path: standard, stableId: stableId
        )
        notifyProjectsChanged()
        return project
    }

    func project(withStableId stableId: String) -> Project? {
        (pinnedProjects + activeGroups.flatMap(\.projects) + archivedProjects)
            .first { $0.stableId == stableId }
    }

    func beginEditing(_ project: Project) {
        editDraft = SidebarProjectEditDraft(
            id: project.id,
            name: project.name,
            group: project.group ?? "",
            tags: project.tags.joined(separator: ", ")
        )
    }

    func requestRemoval(of project: Project) {
        pendingRemoval = SidebarProjectRemoval(
            id: project.id,
            stableId: project.stableId,
            name: project.name
        )
    }

    func setPinned(_ pinned: Bool, projectId: UUID,
                   deps: AppDependencies, ctx: ModelContext) throws {
        try deps.projectRegistry(in: ctx).setPinned(id: projectId, pinned: pinned)
        notifyProjectsChanged()
    }

    func updateOrganization(
        projectId: UUID,
        group: String,
        tags: String,
        deps: AppDependencies,
        ctx: ModelContext
    ) throws {
        let normalizedGroup = Self.normalizedGroup(group)
        let normalizedTags = Self.normalizedTags(tags)
        try deps.projectRegistry(in: ctx).updateOrganization(
            id: projectId,
            group: normalizedGroup,
            tags: normalizedTags
        )
        editDraft = nil
        notifyProjectsChanged()
    }

    func removeProject(
        _ removal: SidebarProjectRemoval,
        deps: AppDependencies,
        ctx: ModelContext
    ) throws {
        try deps.projectRegistry(in: ctx).unregister(id: removal.id)
        pendingRemoval = nil
        notifyProjectsChanged()
    }

    func markOpened(
        stableId: String,
        at date: Date = Date(),
        deps: AppDependencies,
        ctx: ModelContext
    ) throws {
        guard let project = project(withStableId: stableId) else { return }
        try deps.projectRegistry(in: ctx).markOpened(id: project.id, at: date)
        notifyProjectsChanged()
    }

    func isPathMissing(for project: Project) -> Bool {
        missingProjectIds.contains(project.id)
    }

    func relocateProject(
        id: UUID,
        to path: String,
        deps: AppDependencies,
        ctx: ModelContext
    ) throws {
        try deps.projectRegistry(in: ctx).relocate(id: id, to: path)
        missingProjectIds.remove(id)
        notifyProjectsChanged()
    }

    static func normalizedGroup(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func normalizedTags(_ raw: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",，\n")
        var seen: Set<String> = []
        return raw
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func notifyProjectsChanged() {
        NotificationCenter.default.post(name: Self.projectsChangedNotification, object: nil)
    }
}
