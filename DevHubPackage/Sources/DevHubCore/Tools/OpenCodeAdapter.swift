import Foundation

/// OpenCode adapter（§工具管理）。
///
/// OpenCode（opencode.ai）是基于终端的 AI 编码 CLI，全局命令 `opencode`，
/// 通过 `npm install -g opencode-ai` 安装（installCommand 仅传给 `npm` 的后半段）。
/// 支持会话恢复与位置参数注入项目记忆，与 Claude/Codex 同形态。
public struct OpenCodeAdapter: ToolAdapter {
    public let toolId = "opencode"
    public let executablePath = "opencode"
    public let requiresPTY = true
    public let capabilities: ToolCapabilities = [.canInjectPositional, .canResume]
    public let installMethod: InstallMethod = .npm
    public let installCommand: String? = "install -g opencode-ai"
    public let downloadURL: String? = "https://opencode.ai/docs/"

    public init() {}

    public func launchNew(ctx: LaunchContext) async throws -> ToolInstance {
        let cmd = try await buildCommand(ctx: ctx)
        return .cli(launchScriptPath: try await LauncherScriptBuilder.shared.write(
            cwd: ctx.projectPath, executable: cmd.executable, arguments: cmd.arguments,
            environment: ctx.environment, cleanupPaths: ctx.renderedMemoryFile.map { [$0] } ?? []
        ))
    }

    public func resume(sessionId: String, ctx: LaunchContext) async throws -> ToolInstance {
        let cmd = try await buildCommand(ctx: LaunchContext(
            projectPath: ctx.projectPath, renderedMemoryFile: ctx.renderedMemoryFile,
            sessionId: sessionId, tool: ctx.tool, environment: ctx.environment
        ))
        return .cli(launchScriptPath: try await LauncherScriptBuilder.shared.write(
            cwd: ctx.projectPath, executable: cmd.executable, arguments: cmd.arguments,
            environment: ctx.environment, cleanupPaths: ctx.renderedMemoryFile.map { [$0] } ?? []
        ))
    }

    /// 纯函数：构造命令（便于测试）。OpenCode 用 `resume <id>` 恢复，记忆走位置参数。
    public func buildCommand(ctx: LaunchContext) async throws -> CommandSpec {
        var args: [String] = []
        if let sid = ctx.sessionId { args.append(contentsOf: ["resume", sid]) }
        if let mem = ctx.renderedMemoryFile {
            args.append("$__DEVHUB_MEMORY_FILE__\(mem)")
        }
        return try ConfiguredCommand.parse(
            ctx.tool?.launchCommand,
            fallbackExecutable: executablePath,
            appending: args
        )
    }
}
