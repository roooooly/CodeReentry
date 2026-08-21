import Foundation

/// Aider exposes one continuing default history per project. Resuming launches
/// the configured executable in that project with `--restore-chat-history`;
/// the project path is the durable identity, so no synthetic session ID is
/// passed to Aider.
public struct AiderAdapter: ToolAdapter {
    public let toolId = "aider"
    public let executablePath = "aider"
    public let requiresPTY = true
    public let capabilities: ToolCapabilities = [.canResume]
    public let installMethod: InstallMethod = .manual
    public let installCommand: String? = nil
    public let downloadURL: String? = "https://aider.chat/docs/install.html"

    public init() {}

    public func launchNew(ctx: LaunchContext) async throws -> ToolInstance {
        let command = try await buildCommand(ctx: ctx)
        return .cli(launchScriptPath: try await LauncherScriptBuilder.shared.write(
            cwd: ctx.projectPath,
            executable: command.executable,
            arguments: command.arguments,
            environment: ctx.environment
        ))
    }

    public func resume(sessionId: String, ctx: LaunchContext) async throws -> ToolInstance {
        let command = try await buildCommand(ctx: LaunchContext(
            projectPath: ctx.projectPath,
            renderedMemoryFile: nil,
            sessionId: sessionId,
            tool: ctx.tool,
            environment: ctx.environment
        ))
        return .cli(launchScriptPath: try await LauncherScriptBuilder.shared.write(
            cwd: ctx.projectPath,
            executable: command.executable,
            arguments: command.arguments,
            environment: ctx.environment
        ))
    }

    public func buildCommand(ctx: LaunchContext) async throws -> CommandSpec {
        let arguments = ctx.sessionId == nil ? [] : ["--restore-chat-history"]
        return try ConfiguredCommand.parse(
            ctx.tool?.launchCommand,
            fallbackExecutable: executablePath,
            appending: arguments
        )
    }
}
