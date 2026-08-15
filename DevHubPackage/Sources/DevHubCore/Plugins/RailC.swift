import Foundation

// MARK: - Rail C 脚本插件 manifest（§6.4）
// 与 P1 Rail A 的 PluginManifest 区分：Rail C 是磁盘 manifest.json + action.js。

public enum ScriptPluginPermission: String, Codable, Sendable, Equatable {
    case filesystem, network, process, automation
}

public enum ActionScope: String, Codable, Sendable, Equatable {
    case project, global, session
}

public struct ScriptPluginAction: Equatable, Codable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let scope: ActionScope
    public let run: String       // 相对 plugin dir 的脚本路径 "action.js"

    public init(id: String, title: String, scope: ActionScope, run: String) {
        self.id = id; self.title = title; self.scope = scope; self.run = run
    }
}

public struct ScriptPluginContributions: Equatable, Codable, Sendable {
    public let actions: [ScriptPluginAction]
    public init(actions: [ScriptPluginAction]) { self.actions = actions }
}

public struct ScriptPluginManifest: Equatable, Codable, Sendable {
    public let name: String
    public let version: String
    public let permissions: [ScriptPluginPermission]
    public let contributions: ScriptPluginContributions
    public var minAppVersion: String?

    enum CodingKeys: String, CodingKey {
        case name, version, permissions, contributions, minAppVersion
    }

    public init(name: String, version: String, permissions: [ScriptPluginPermission],
                contributions: ScriptPluginContributions, minAppVersion: String? = nil) {
        self.name = name; self.version = version; self.permissions = permissions
        self.contributions = contributions; self.minAppVersion = minAppVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        permissions = try c.decode([ScriptPluginPermission].self, forKey: .permissions)
        contributions = try c.decode(ScriptPluginContributions.self, forKey: .contributions)
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
    }
}

// MARK: - Registry（扫描，不执行）

public struct DiscoveredScriptPlugin: Equatable, Sendable, Identifiable {
    public let id: String          // 目录名
    public let dir: URL
    public let manifest: ScriptPluginManifest
}

public struct ScriptPluginActionRef: Equatable, Sendable {
    public let pluginId: String
    public let pluginDir: URL
    public let action: ScriptPluginAction
    public let minAppVersion: String?

    public init(
        pluginId: String,
        pluginDir: URL,
        action: ScriptPluginAction,
        minAppVersion: String? = nil
    ) {
        self.pluginId = pluginId
        self.pluginDir = pluginDir
        self.action = action
        self.minAppVersion = minAppVersion
    }
}

/// Rail C manifest 使用的纯数字版本比较（例如 0.10.0 > 0.9.0）。
/// 无法解析的版本按不兼容处理，避免插件绕过 `minAppVersion` 门槛。
public enum ScriptPluginVersion {
    public static func isCompatible(current: String, minimum: String?) -> Bool {
        guard let minimum else { return true }
        guard let currentParts = components(of: current),
              let minimumParts = components(of: minimum) else { return false }

        let count = max(currentParts.count, minimumParts.count)
        for index in 0..<count {
            let currentPart = index < currentParts.count ? currentParts[index] : 0
            let minimumPart = index < minimumParts.count ? minimumParts[index] : 0
            if currentPart != minimumPart { return currentPart > minimumPart }
        }
        return true
    }

    private static func components(of raw: String) -> [Int]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withoutMetadata = trimmed.split(separator: "+", maxSplits: 1).first.map(String.init) ?? trimmed
        let core = withoutMetadata.split(separator: "-", maxSplits: 1).first.map(String.init) ?? withoutMetadata
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }
        var result: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber), let value = Int(part) else { return nil }
            result.append(value)
        }
        return result
    }
}

/// 扫描 `~/Library/Application Support/DevHub/plugins/<name>/manifest.json`（§6.4）。
public struct ScriptPluginRegistry: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public func scan() -> [DiscoveredScriptPlugin] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var plugins: [DiscoveredScriptPlugin] = []
        for dir in entries where isDir(dir) {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(ScriptPluginManifest.self, from: data) else {
                continue
            }
            plugins.append(DiscoveredScriptPlugin(id: dir.lastPathComponent, dir: dir, manifest: manifest))
        }
        return plugins.sorted { $0.id < $1.id }
    }

    public func allActions() -> [ScriptPluginActionRef] {
        scan().flatMap { p in
            p.manifest.contributions.actions.map { a in
                ScriptPluginActionRef(
                    pluginId: p.id,
                    pluginDir: p.dir,
                    action: a,
                    minAppVersion: p.manifest.minAppVersion
                )
            }
        }
    }

    func isDir(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DevHub/plugins")
    }
}
