import Testing
import Foundation
@testable import DevHubCore

@Suite("ZcodeAdapter")
struct ZcodeAdapterTests {

    let adapter = ZcodeAdapter()

    @Test("identity reflects zcode CLI entry")
    func identity() {
        #expect(adapter.toolId == "zcode")
        // 真实入口：ZCode.app bundle 内的 zcode.cjs
        #expect(adapter.executablePath.contains("zcode") || adapter.executablePath.contains("ZCode"))
    }

    @Test("capabilities: 可注入位置参数 + 可 resume")
    func capabilitiesValid() {
        #expect(adapter.capabilities.contains(.canInjectPositional))
        #expect(adapter.capabilities.contains(.canResume))
        #expect(adapter.capabilities.isSubset(of: [
            .canInjectSystemPrompt, .canInjectPositional, .canResume, .canOpenGUI
        ]))
    }

    @Test("buildCommand 无 session/memory → --cwd + 无 --resume/--prompt")
    func buildCommandPlain() async throws {
        let cmd = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/proj", renderedMemoryFile: nil, sessionId: nil, tool: nil
        ))
        #expect(cmd.arguments.contains("node"))
        #expect(cmd.arguments.contains("--cwd"))
        #expect(cmd.arguments.contains("/tmp/proj"))
        #expect(!cmd.arguments.contains("--resume"))
        #expect(!cmd.arguments.contains("--prompt"))
    }

    @Test("buildCommand 带 sessionId → --resume <sid>")
    func buildCommandResume() async throws {
        let cmd = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/proj", renderedMemoryFile: nil,
            sessionId: "sess_abc123", tool: nil
        ))
        let resumeIdx = try #require(cmd.arguments.firstIndex(of: "--resume"))
        #expect(cmd.arguments[resumeIdx + 1] == "sess_abc123")
    }

    @Test("buildCommand 带 memory → --prompt <占位符>")
    func buildCommandInjectMemory() async throws {
        let cmd = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/proj",
            renderedMemoryFile: "/tmp/mem.md",
            sessionId: nil, tool: nil
        ))
        let promptIdx = try #require(cmd.arguments.firstIndex(of: "--prompt"))
        // LauncherScriptBuilder 会把 $__DEVHUB_MEMORY_FILE__<path> 展开为 $(cat '<path>')
        #expect(cmd.arguments[promptIdx + 1].contains("$__DEVHUB_MEMORY_FILE__"))
        #expect(cmd.arguments[promptIdx + 1].contains("/tmp/mem.md"))
    }
}
