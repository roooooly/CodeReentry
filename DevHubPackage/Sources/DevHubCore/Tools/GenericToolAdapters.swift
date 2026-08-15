import Foundation

/// 用户自定义 CLI adapter。固定参数来自 `launchCommand`，可选记忆参数来自
/// `injectionArgs` 的显式占位符；所有内容最终仍由 LauncherScriptBuilder 逐 argv 引用。
public struct GenericCLIAdapter: ToolAdapter {
    public let toolId = "custom-cli"
    public let executablePath = ""
    public let requiresPTY = true
    public let capabilities: ToolCapabilities

    public init(injectionMode: InjectionMode?, injectionArguments: [String]?) {
        let arguments = injectionArguments ?? []
        switch injectionMode {
        case .cliFlag where arguments.contains("{memoryFile}"):
            capabilities = [.canInjectSystemPrompt]
        case .positionalArg where arguments.contains("{memory}"):
            capabilities = [.canInjectPositional]
        default:
            capabilities = []
        }
    }

    public func launchNew(ctx: LaunchContext) async throws -> ToolInstance {
        guard let tool = ctx.tool else {
            throw AdapterError.unsupported(String(localized: "自定义 CLI 缺少工具配置"))
        }
        var appended: [String] = []
        if let memoryFile = ctx.renderedMemoryFile {
            appended = (tool.injectionArgs ?? []).map { argument in
                switch argument {
                case "{memoryFile}":
                    return memoryFile
                case "{memory}":
                    return "$__DEVHUB_MEMORY_FILE__\(memoryFile)"
                default:
                    return argument
                }
            }
        }
        let command = try ConfiguredCommand.parse(
            tool.launchCommand,
            fallbackExecutable: "",
            appending: appended
        )
        let path = try await LauncherScriptBuilder.shared.write(
            cwd: ctx.projectPath,
            executable: command.executable,
            arguments: command.arguments,
            environment: ctx.environment,
            cleanupPaths: ctx.renderedMemoryFile.map { [$0] } ?? []
        )
        return .cli(launchScriptPath: path)
    }

    public func resume(sessionId: String, ctx: LaunchContext) async throws -> ToolInstance {
        throw AdapterError.unsupported(String(localized: "自定义 CLI 未配置会话恢复模板"))
    }
}

/// 用户自定义 GUI 工具。`launchCommand` 可填写 bundle identifier 或 `.app` 路径。
public struct GenericGUIAdapter: ToolAdapter {
    public let toolId = "custom-app"
    public let executablePath: String
    public let requiresPTY = false
    public let capabilities: ToolCapabilities = .canOpenGUI

    public init(configuredIdentifier: String) {
        executablePath = configuredIdentifier
    }

    public func launchNew(ctx: LaunchContext) async throws -> ToolInstance {
        let raw = ctx.tool?.launchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw ConfiguredCommandError.empty }
        let expanded = (raw as NSString).expandingTildeInPath
        let bundleId: String
        if expanded.hasSuffix(".app") {
            guard let identifier = Bundle(path: expanded)?.bundleIdentifier else {
                throw AdapterError.unsupported(String(localized: "无法从 App 路径读取 bundle identifier：\(expanded)"))
            }
            bundleId = identifier
        } else {
            bundleId = raw
        }
        return .gui(bundleId: bundleId)
    }

    public func resume(sessionId: String, ctx: LaunchContext) async throws -> ToolInstance {
        try await launchNew(ctx: ctx)
    }
}
