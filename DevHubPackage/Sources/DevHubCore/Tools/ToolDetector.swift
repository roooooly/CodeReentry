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
/// 1. `Tool.detectPath`（用户显式覆盖路径）；
/// 2. adapter 的 `executablePath`（绝对路径直接 FileManager 探测；裸名走 PATH 搜索）；
/// 3. `Tool.launchCommand` 首段（兜底）。
///
/// PATH 搜索范围与 `LocalProcessRunner` 的注入一致（homebrew / local / npm-global），
/// 这样 UI 上"已安装"判断与真正执行命令时的 PATH 解析保持同源。
public struct ToolDetector: Sendable {
    public init() {}

    public func probe(executableHint: String?, detectPath: String?, launchCommand: String?) -> PathProbeResult {
        let fileManager = FileManager.default
        // 1. 显式覆盖
        if let explicit = detectPath?.trimmingCharacters(in: .whitespacesAndNewlines), !explicit.isEmpty {
            let expanded = (explicit as NSString).expandingTildeInPath
            if fileManager.fileExists(atPath: expanded) {
                return .found(absolutePath: expanded)
            }
        }
        // 2. adapter executablePath
        let candidates = [executableHint, firstSegment(of: launchCommand)].compactMap { $0 }
        for candidate in candidates {
            let resolved = resolve(candidate)
            if fileManager.fileExists(atPath: resolved.path) {
                return .found(absolutePath: resolved.path)
            }
            if resolved.viaPathLookup, let hit = Self.searchPATH(name: candidate) {
                return .found(absolutePath: hit)
            }
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

    private func firstSegment(of launchCommand: String?) -> String? {
        guard let raw = launchCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
              let first = raw.split(separator: " ").first else { return nil }
        return String(first)
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
