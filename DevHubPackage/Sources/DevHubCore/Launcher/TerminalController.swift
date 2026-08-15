import Foundation

public enum TerminalTarget: String, Sendable, CaseIterable {
    case terminal
    case iterm2

    public var appName: String {
        switch self {
        case .terminal: return "Terminal"
        case .iterm2:   return "iTerm"
        }
    }
    public var bundleId: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm2:   return "com.googlecode.iterm2"
        }
    }
}

/// §5.2 方案 B AppleScript 部分。
/// AppleScript **只接收 launcher script 路径**（经引用），**原始记忆内容绝不拼进 AppleScript 源码**。
///
/// 注：`executor` 设计成可替换属性——单元测试不能真的启动 Terminal.app（会触发 TCC 授权弹窗并阻塞），
/// 所以测试时注入 no-op executor；生产路径用默认 `realAppleScriptExecutor`。
@MainActor
public final class TerminalController {

    public init() {}

    /// 测试 hook：最近一次执行的 launcher script 路径
    public private(set) var lastLauncherPath: String?

    public enum TerminalError: Error, Equatable {
        case scriptCompileFailed(String)
        case executionFailed(String)
    }

    /// AppleScript 执行器。默认实现走 NSAppleScript；测试可替换为 no-op。
    public var executor: @MainActor (String) throws -> [String: Any]? = TerminalController.realAppleScriptExecutor

    public func buildAppleScript(terminal: TerminalTarget, launcherPath: String) -> String {
        let quotedPath = escapeAppleScript(launcherPath)
        switch terminal {
        case .terminal:
            return """
            tell application "\(terminal.appName)"
                activate
                do script "\(quotedPath)"
            end tell
            """
        case .iterm2:
            return """
            tell application "\(terminal.appName)"
                activate
                create window with default profile
                tell current session of current window
                    write session text "\(quotedPath)"
                end tell
            end tell
            """
        }
    }

    @discardableResult
    public func execute(terminal: TerminalTarget, launcherPath: String) async throws -> [String: Any]? {
        self.lastLauncherPath = launcherPath
        let source = buildAppleScript(terminal: terminal, launcherPath: launcherPath)
        return try executor(source)
    }

    private func escapeAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 默认 AppleScript 执行器——通过 NSAppleScript 执行。
    /// 注：执行会触发 TCC 自动化授权；未授权或后台线程上下文可能阻塞。
    /// 生产代码应在主线程调用，或包装到 DispatchQueue.main.sync 中。
    private static func realAppleScriptExecutor(_ source: String) throws -> [String: Any]? {
        let appleScript = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let descriptor = appleScript?.executeAndReturnError(&errorInfo)
        if let err = errorInfo as? [String: Any] {
            throw TerminalError.executionFailed(err[NSAppleScript.errorMessage] as? String ?? "unknown")
        }
        return descriptor?.description.isEmpty == false
            ? ["result": descriptor?.description ?? ""]
            : nil
    }
}
