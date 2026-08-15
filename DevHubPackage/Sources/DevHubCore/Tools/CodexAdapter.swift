import Foundation

/// codex adapter（§5.2，已实地核验 resume --help）。
/// 注入走位置参数 PROMPT，**语义是"发送一条用户消息并立即开始新一轮对话"，不是系统上下文**。
public struct CodexAdapter: ToolAdapter {
    public let toolId = "codex"
    public let executablePath = "/Applications/ChatGPT.app/Contents/Resources/codex"
    public let requiresPTY = true
    public let capabilities: ToolCapabilities = [.canInjectPositional, .canResume]

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

    public func buildCommand(ctx: LaunchContext) async throws -> CommandSpec {
        var args: [String] = []
        if let sid = ctx.sessionId {
            args.append(contentsOf: ["resume", sid])
        }
        if let mem = ctx.renderedMemoryFile {
            // 占位符由 LauncherScriptBuilder (Task 25) 替换为 $(cat '<mem>')
            args.append("$__DEVHUB_MEMORY_FILE__\(mem)")
        }
        return try ConfiguredCommand.parse(
            ctx.tool?.launchCommand,
            fallbackExecutable: executablePath,
            appending: args
        )
    }
}
