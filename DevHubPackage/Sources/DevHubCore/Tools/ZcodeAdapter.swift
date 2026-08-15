import Foundation

/// zcode adapter（§5.2）。
///
/// zcode CLI 真实入口（实地核验 `--help`，zcode 0.15.2）：
///   `node /Applications/ZCode.app/Contents/Resources/glm/zcode.cjs [options]`
/// 支持 `--resume <sessionId>`（id 格式 `sess_<uuid>`，与 ZcodeReader 产出一致）、
/// `--prompt <text>`（位置参数注入，`--prompt` 单轮模式）、`--cwd <path>`。
/// 与 codex/claude 同构，故镜像 CodexAdapter 的注入/resume 模式。
///
/// 注：依赖系统 `node`（通过 `/usr/bin/env node` 解析）。若用户机器无 node，
/// 启动会失败并报错——这是可接受的明确失败，优于静默 nil。
public struct ZcodeAdapter: ToolAdapter {
    public let toolId = "zcode"
    /// 用于显示的脚本路径（真实 argv 由 buildCommand 构造，走 /usr/bin/env node）。
    public let executablePath = "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs"
    public let requiresPTY = true
    public let capabilities: ToolCapabilities = [.canInjectPositional, .canResume]

    /// zcode.cjs 脚本绝对路径（buildCommand 写进 argv）。
    private static let zcodeScript = "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs"

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
        let configured = try ConfiguredCommand.parse(
            ctx.tool?.launchCommand,
            fallbackExecutable: Self.zcodeScript
        )
        // .cjs 由 node 执行；若用户配置的是可执行包装器，则直接调用。
        let executable: String
        var args: [String]
        if configured.executable.hasSuffix(".cjs") {
            executable = "/usr/bin/env"
            args = ["node", configured.executable] + configured.arguments + ["--cwd", ctx.projectPath]
        } else {
            executable = configured.executable
            args = configured.arguments + ["--cwd", ctx.projectPath]
        }
        if let sid = ctx.sessionId {
            args += ["--resume", sid]
        }
        if let mem = ctx.renderedMemoryFile {
            // 占位符由 LauncherScriptBuilder 替换为 $(cat '<mem>')
            args += ["--prompt", "$__DEVHUB_MEMORY_FILE__\(mem)"]
        }
        return CommandSpec(executable: executable, arguments: args)
    }
}
