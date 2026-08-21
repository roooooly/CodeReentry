import Foundation

/// Pi CLI adapter pinned to the v0.84.2 exact-file resume contract.
public struct PiAdapter: ToolAdapter {
    public let toolId = "pi"
    public let executablePath = "pi"
    public let requiresPTY = true
    public let capabilities: ToolCapabilities = [.canResume]
    public let installMethod: InstallMethod = .npm
    public let installCommand: String? = "install -g --ignore-scripts @earendil-works/pi-coding-agent"
    public let downloadURL: String? = "https://github.com/earendil-works/pi/tree/v0.84.2/packages/coding-agent"

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
        let arguments = ctx.sessionId.map { ["--session", $0] } ?? []
        return try ConfiguredCommand.parse(
            ctx.tool?.launchCommand,
            fallbackExecutable: executablePath,
            appending: arguments
        )
    }
}
