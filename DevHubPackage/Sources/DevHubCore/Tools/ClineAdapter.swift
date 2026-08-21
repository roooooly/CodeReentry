import Foundation

/// Cline CLI adapter pinned to the v3.0.56 exact-session resume contract.
public struct ClineAdapter: ToolAdapter {
    public let toolId = "cline"
    public let executablePath = "cline"
    public let requiresPTY = true
    public let capabilities: ToolCapabilities = [.canResume]
    public let installMethod: InstallMethod = .npm
    public let installCommand: String? = "install -g cline"
    public let downloadURL: String? = "https://docs.cline.bot/getting-started/installing-cline"

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
        let arguments = ctx.sessionId.map { ["--id", $0] } ?? []
        return try ConfiguredCommand.parse(
            ctx.tool?.launchCommand,
            fallbackExecutable: executablePath,
            appending: arguments
        )
    }
}
