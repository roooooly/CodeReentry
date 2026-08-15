import Foundation

/// 工具能力（§5.2）。OptionSet——避免 UI 承诺与实际不符。
public struct ToolCapabilities: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let canInjectSystemPrompt = ToolCapabilities(rawValue: 1 << 0)
    public static let canInjectPositional   = ToolCapabilities(rawValue: 1 << 1)
    public static let canResume             = ToolCapabilities(rawValue: 1 << 2)
    public static let canOpenGUI            = ToolCapabilities(rawValue: 1 << 3)
}

/// 启动上下文（§5.2）。
/// 注：`Tool` 是 SwiftData `@Model` class（非 Sendable），但 LaunchContext 只承载
/// 启动时的只读快照，因此用 `@unchecked Sendable` 标记——adapter 不会跨线程变更它。
public struct LaunchContext: @unchecked Sendable {
    public let projectPath: String
    public let renderedMemoryFile: String?
    public let sessionId: String?
    public let tool: Tool?
    /// 启动时的环境变量快照（普通值 + 从 Keychain 取出的 secret 值）。
    public let environment: [String: String]

    public init(projectPath: String, renderedMemoryFile: String?, sessionId: String?, tool: Tool?,
                environment: [String: String] = [:]) {
        self.projectPath = projectPath
        self.renderedMemoryFile = renderedMemoryFile
        self.sessionId = sessionId
        self.tool = tool
        self.environment = environment
    }
}

/// 启动产物（§5.2）。
public enum ToolInstance: Sendable, Equatable {
    case cli(launchScriptPath: String)
    case gui(bundleId: String)
}

/// 命令构造产物（executable + arguments 数组）。不 shell 拼接（§8.1）。
public struct CommandSpec: Sendable, Equatable {
    public let executable: String
    public let arguments: [String]
    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public enum AdapterError: Error, Equatable {
    case launcherNotReady
    case notYetVerified
    case unsupported(String)
}

/// 工具适配器（§5.2）。
public protocol ToolAdapter: Sendable {
    var toolId: String { get }
    var executablePath: String { get }
    var requiresPTY: Bool { get }
    var capabilities: ToolCapabilities { get }
    func launchNew(ctx: LaunchContext) async throws -> ToolInstance
    func resume(sessionId: String, ctx: LaunchContext) async throws -> ToolInstance
}

public extension ToolAdapter {
    /// 取版本号时附加的参数；默认 `--version`。某些工具（如 codex）用 `--version` 之外的子命令。
    var versionArguments: [String] { ["--version"] }

    /// 安装方式：用于"未安装 → 一键安装"。默认 `.manual`（打开下载页）。
    var installMethod: InstallMethod { .manual }

    /// 安装命令（brew/npm 后半段）。默认 nil = 手动安装。
    var installCommand: String? { nil }

    /// 下载页 URL（manual 安装时打开）。
    var downloadURL: String? { nil }
}
