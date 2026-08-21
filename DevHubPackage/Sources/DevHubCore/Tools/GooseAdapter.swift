import Foundation

/// Goose CLI adapter pinned to the v1.46.0 exact-session resume contract.
public struct GooseAdapter: ToolAdapter {
    public let toolId = "goose"
    public let executablePath = "goose"
    public let requiresPTY = true
    public let capabilities: ToolCapabilities = [.canResume]
    public let installMethod: InstallMethod = .brew
    public let installCommand: String? = "install block-goose-cli"
    public let downloadURL: String? = "https://block.github.io/goose/docs/getting-started/installation/"

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
        let arguments = ctx.sessionId.map {
            ["session", "--resume", "--session-id", $0]
        } ?? ["session"]
        return try ConfiguredCommand.parse(
            ctx.tool?.launchCommand,
            fallbackExecutable: executablePath,
            appending: arguments
        )
    }
}
