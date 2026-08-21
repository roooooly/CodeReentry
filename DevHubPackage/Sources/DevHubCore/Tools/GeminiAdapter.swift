import Foundation

/// Google Gemini CLI adapter.
///
/// Gemini CLI resumes an exact project-scoped session with
/// `gemini --resume <uuid>`. Session discovery supplies the original project
/// root so Gemini looks in the matching local session directory.
public struct GeminiAdapter: ToolAdapter {
    public let toolId = "gemini-cli"
    public let executablePath = "gemini"
    public let requiresPTY = true
    public let capabilities: ToolCapabilities = [.canResume]
    public let installMethod: InstallMethod = .npm
    public let installCommand: String? = "install -g @google/gemini-cli"
    public let downloadURL: String? = "https://github.com/google-gemini/gemini-cli"

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
        let arguments = ctx.sessionId.map { ["--resume", $0] } ?? []
        return try ConfiguredCommand.parse(
            ctx.tool?.launchCommand,
            fallbackExecutable: executablePath,
            appending: arguments
        )
    }
}
