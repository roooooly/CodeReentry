import Foundation

public enum ScriptPluginPermissionStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidStateFile(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStateFile(let path):
            return String(localized: "插件权限文件无法读取或格式已损坏，为避免覆盖原数据已停止写入：\(path)")
        }
    }
}

/// 单个插件的确认状态（§6.4 首次启用确认）。
public struct ScriptPluginPermissionState: Codable, Equatable, Sendable {
    public let pluginId: String
    public let confirmedPermissions: [ScriptPluginPermission]
    public let confirmedAt: Date

    public init(pluginId: String, confirmedPermissions: [ScriptPluginPermission], confirmedAt: Date) {
        self.pluginId = pluginId
        self.confirmedPermissions = confirmedPermissions
        self.confirmedAt = confirmedAt
    }
}

/// 插件启用确认状态存储（§6.4）。不入 SwiftData，存 `.permissions.json` 单文件。
/// 运行时强制留 v2；本 store 只记录"用户已确认启用某插件 + 当时确认的权限列表"。
public actor ScriptPluginPermissionStore {
    private let file: URL
    private var cache: [String: ScriptPluginPermissionState] = [:]
    private var loaded = false
    private var loadFailure: ScriptPluginPermissionStoreError?

    public init(file: URL) { self.file = file }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            cache = try JSONDecoder().decode([String: ScriptPluginPermissionState].self, from: data)
        } catch {
            loadFailure = .invalidStateFile(file.path)
        }
    }

    private func persist(_ proposedCache: [String: ScriptPluginPermissionState]) throws {
        let data = try JSONEncoder().encode(proposedCache)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let temporary = directory.appendingPathComponent(
            ".permissions-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? FileManager.default.removeItem(at: temporary) }

        // 先在同目录的临时文件上完成权限收紧，再原子替换目标。这样 chmod 失败时
        // 旧文件不会已经被新状态覆盖，也不会短暂暴露为默认的 0644。
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: temporary.path
        )
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(
                file,
                withItemAt: temporary,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: temporary, to: file)
        }
    }

    public func isConfirmed(pluginId: String) -> Bool {
        loadIfNeeded()
        return cache[pluginId] != nil
    }

    public func state(pluginId: String) -> ScriptPluginPermissionState? {
        loadIfNeeded()
        return cache[pluginId]
    }

    public func loadError() -> ScriptPluginPermissionStoreError? {
        loadIfNeeded()
        return loadFailure
    }

    public func confirm(pluginId: String, permissions: [ScriptPluginPermission]) throws {
        loadIfNeeded()
        if let loadFailure { throw loadFailure }
        var proposedCache = cache
        proposedCache[pluginId] = ScriptPluginPermissionState(
            pluginId: pluginId, confirmedPermissions: permissions, confirmedAt: Date())
        try persist(proposedCache)
        cache = proposedCache
    }

    public func revoke(pluginId: String) throws {
        loadIfNeeded()
        if let loadFailure { throw loadFailure }
        guard cache[pluginId] != nil else { return }
        var proposedCache = cache
        proposedCache[pluginId] = nil
        try persist(proposedCache)
        cache = proposedCache
    }

    /// 权限列表变化时需重新确认（current = manifest 当前声明，confirmed = 用户上次确认的）。
    public nonisolated func needsReconfirm(current: [ScriptPluginPermission], confirmed: [ScriptPluginPermission]) -> Bool {
        let currentSet = Set(current)
        let confirmedSet = Set(confirmed)
        return !currentSet.isSubset(of: confirmedSet)  // current 有 confirmed 未覆盖的权限
    }

    /// 规范的权限文件路径（与 ScriptPluginRegistry.defaultRoot 同目录）。
    /// AppDependencies 与 Settings/命令面板共享同一个 store 实例。
    public static var defaultPermissionsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevHub/plugins")
            .appendingPathComponent(".permissions.json")
    }
}
