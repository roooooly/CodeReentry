import Foundation
import SwiftData

public enum ProjectRegistryError: LocalizedError, Equatable {
    case duplicatePath
    case duplicateStableId(String)
    case notFound(UUID)
    case invalidPath
    case stableIdMismatch(expected: String, found: String)

    public var errorDescription: String? {
        switch self {
        case .duplicatePath:
            return String(localized: "该项目目录已经注册。")
        case .duplicateStableId:
            return String(localized: "该目录与另一个已注册项目具有相同的本地身份。")
        case .notFound:
            return String(localized: "项目记录已经不存在。")
        case .invalidPath:
            return String(localized: "项目目录不存在或不是文件夹。")
        case .stableIdMismatch:
            return String(localized: "所选目录属于另一个项目，无法替换当前项目路径。")
        }
    }
}

/// §5.1 注册表 CRUD + 组织（tags/pin/group）。
/// ModelContext 由调用方注入；本类无状态。
@MainActor
public final class ProjectRegistry {
    private let ctx: ModelContext

    public init(modelContext: ModelContext) {
        self.ctx = modelContext
    }

    @discardableResult
    public func register(
        name: String, path: String, stableId: String,
        icon: String? = nil, color: String? = nil
    ) throws -> Project {
        let normalized = (path as NSString).standardizingPath
        let projectURL = URL(fileURLWithPath: normalized, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProjectRegistryError.invalidPath
        }

        let dupe = FetchDescriptor<Project>(
            predicate: #Predicate { $0.path == normalized }
        )
        if !(try ctx.fetch(dupe).isEmpty) {
            throw ProjectRegistryError.duplicatePath
        }

        // `.devhub/project.local.json` 是项目跨机器身份的单一锚点。已有文件优先，
        // 不能每次注册都生成一个新 stableId。
        let resolvedStableId = try PathLocator.ensureDevHub(at: projectURL, stableId: stableId)
        let stable = resolvedStableId
        let sameStableId = try ctx.fetch(FetchDescriptor<Project>(
            predicate: #Predicate { $0.stableId == stable }
        )).first
        if let existing = sameStableId {
            // 常见恢复场景：旧路径已不存在，用户把同一个项目重新注册到新路径。
            // 此时更新原记录而不是制造第二个相同身份的项目。
            if !FileManager.default.fileExists(atPath: existing.path) {
                existing.name = name
                existing.path = normalized
                try DefaultToolCatalog.bindEnabledTools(to: existing, in: ctx)
                try ctx.save()
                return existing
            }
            throw ProjectRegistryError.duplicateStableId(resolvedStableId)
        }

        let p = Project(
            stableId: resolvedStableId, name: name, path: normalized,
            icon: icon, color: color
        )
        try DefaultToolCatalog.bindEnabledTools(to: p, in: ctx)
        ctx.insert(p)
        try ctx.save()
        return p
    }

    public func unregister(id: UUID) throws {
        guard let p = try find(id: id) else { throw ProjectRegistryError.notFound(id) }
        ctx.delete(p)
        try ctx.save()
    }

    public func updateTags(id: UUID, tags: [String]) throws {
        guard let p = try find(id: id) else { throw ProjectRegistryError.notFound(id) }
        p.tags = tags
        try ctx.save()
    }

    public func setPinned(id: UUID, pinned: Bool) throws {
        guard let p = try find(id: id) else { throw ProjectRegistryError.notFound(id) }
        p.isPinned = pinned
        try ctx.save()
    }

    public func setGroup(id: UUID, group: String?) throws {
        guard let p = try find(id: id) else { throw ProjectRegistryError.notFound(id) }
        p.group = group
        try ctx.save()
    }

    /// 原子更新项目的侧边栏组织信息，避免 group 与 tags 分两次保存后出现半更新状态。
    public func updateOrganization(id: UUID, group: String?, tags: [String]) throws {
        guard let p = try find(id: id) else { throw ProjectRegistryError.notFound(id) }
        p.group = group
        p.tags = tags
        try ctx.save()
    }

    /// 记录项目最近一次被用户打开的时间，供菜单栏和最近项目排序使用。
    public func markOpened(id: UUID, at date: Date = Date()) throws {
        guard let p = try find(id: id) else { throw ProjectRegistryError.notFound(id) }
        p.lastOpenedAt = date
        try ctx.save()
    }

    /// 把已注册项目重新指向移动后的目录，并保留原项目记录及其所有关系。
    ///
    /// 如果目标目录已有 `.devhub/project.local.json`，其中的 stableId 必须与当前项目一致；
    /// 这可以避免用户误选另一个项目后破坏跨机身份锚点。没有锚点时会写入当前 stableId。
    public func relocate(id: UUID, to path: String) throws {
        guard let project = try find(id: id) else { throw ProjectRegistryError.notFound(id) }

        let normalized = (path as NSString).standardizingPath
        let projectURL = URL(fileURLWithPath: normalized, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ProjectRegistryError.invalidPath
        }

        let matches = try ctx.fetch(FetchDescriptor<Project>(
            predicate: #Predicate { $0.path == normalized }
        ))
        if matches.contains(where: { $0.id != id }) {
            throw ProjectRegistryError.duplicatePath
        }

        if let found = try PathLocator.readStableId(at: projectURL),
           found != project.stableId {
            throw ProjectRegistryError.stableIdMismatch(
                expected: project.stableId,
                found: found
            )
        }

        let anchoredStableId = try PathLocator.ensureDevHub(
            at: projectURL,
            stableId: project.stableId
        )
        guard anchoredStableId == project.stableId else {
            throw ProjectRegistryError.stableIdMismatch(
                expected: project.stableId,
                found: anchoredStableId
            )
        }

        project.path = normalized
        try ctx.save()
    }

    public func list(group: String? = nil) throws -> [Project] {
        var descriptor = FetchDescriptor<Project>(sortBy: [.init(\.name)])
        if let g = group {
            descriptor.predicate = #Predicate { $0.group == g }
        }
        return try ctx.fetch(descriptor)
    }

    public func find(id: UUID) throws -> Project? {
        try ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })).first
    }
}
