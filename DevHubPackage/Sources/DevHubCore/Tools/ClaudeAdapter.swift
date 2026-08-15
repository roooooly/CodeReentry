import Foundation

/// Claude Code adapter（§5.2，已实地核验 --help）。
public struct ClaudeAdapter: ToolAdapter {
    public let toolId = "claude-code"
    public let executablePath = "claude"
    public let requiresPTY = true
    public let capabilities: ToolCapabilities = [.canInjectSystemPrompt, .canResume]

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

    /// 纯函数：构造命令（便于测试）。
    public func buildCommand(ctx: LaunchContext) async throws -> CommandSpec {
        var args: [String] = []
        if let sid = ctx.sessionId { args.append(contentsOf: ["--resume", sid]) }
        if let mem = ctx.renderedMemoryFile {
            args.append(contentsOf: ["--append-system-prompt-file", mem])
        }
        return try ConfiguredCommand.parse(
            ctx.tool?.launchCommand,
            fallbackExecutable: executablePath,
            appending: args
        )
    }
}
