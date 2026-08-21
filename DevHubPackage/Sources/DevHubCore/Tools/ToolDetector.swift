import Foundation

/// 工具安装检测结果（§工具管理 卡片三态）。
public enum ToolInstallState: Sendable, Equatable {
    case installed(version: String?)
    case notInstalled
    case checking
}

/// PATH 探测结果（便于单测，纯值类型）。
public enum PathProbeResult: Sendable, Equatable {
    case found(absolutePath: String)
    case notFound
}

/// 工具安装检测器（§工具管理）。
///
/// 探测顺序：
/// 1. `Tool.detectPath`（用户显式覆盖路径，存在即命中，不存在即失败）；
/// 2. `Tool.launchCommand` 中解析出的可执行文件（用户配置，存在即命中，不存在即失败）；
/// 3. adapter 的 `executablePath`（仅在没有用户配置时兜底）。
///
/// PATH 搜索范围与 `LocalProcessRunner` 的注入一致（homebrew / local / npm-global），
/// 这样 UI 上"已安装"判断与真正执行命令时的 PATH 解析保持同源。
public struct ToolDetector: Sendable {
    public init() {}

    public func probe(executableHint: String?, detectPath: String?, launchCommand: String?) -> PathProbeResult {
        let fileManager = FileManager.default
        // 1. 显式覆盖具有决定性：不能在它失效时悄悄改用另一个命令，
        // 否则“已安装”状态会与 adapter 真正执行的配置不一致。
        if let explicit = detectPath?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            let expanded = (explicit as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                return .found(absolutePath: expanded)
            }
            return .notFound
        }

        // 2. Persisted launchCommand is also authoritative when present.
        if let configured = launchCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configured.isEmpty {
            guard let candidate = executable(in: configured) else { return .notFound }
            return probe(candidate, fileManager: fileManager)
        }

        // 3. Adapter fallback only applies when the user has no persisted command.
        guard let executableHint else { return .notFound }
        return probe(executableHint, fileManager: fileManager)
    }

    private func probe(_ candidate: String, fileManager: FileManager) -> PathProbeResult {
        let resolved = resolve(candidate)
        if fileManager.fileExists(atPath: resolved.path) {
            return .found(absolutePath: resolved.path)
        }
        if resolved.viaPathLookup, let hit = Self.searchPATH(name: candidate, fileManager: fileManager) {
            return .found(absolutePath: hit)
        }
        return .notFound
    }

    /// 解析候选：绝对/相对路径原样，裸名标记为需 PATH 搜索。
    private func resolve(_ candidate: String) -> (path: String, viaPathLookup: Bool) {
        let expanded = (candidate as NSString).expandingTildeInPath
        if expanded.contains("/") {
            return (expanded, false)
        }
        return (expanded, true)
    }

    private func executable(in launchCommand: String?) -> String? {
        try? ConfiguredCommand.parse(
            launchCommand,
            fallbackExecutable: ""
        ).executable
    }

    /// 在常见 PATH 目录里查找可执行名（与 LocalProcessRunner 的 PATH 注入同源）。
    public static func searchPATH(name: String, fileManager: FileManager = .default) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "\(home)/.npm-global/bin", "/usr/bin", "/bin"
        ]
        for dir in dirs {
            let p = "\(dir)/\(name)"
            if fileManager.isExecutableFile(atPath: p) {
                return p
            }
        }
        return nil
    }
}
