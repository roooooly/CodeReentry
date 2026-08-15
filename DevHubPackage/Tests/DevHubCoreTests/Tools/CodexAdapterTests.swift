import Testing
import Foundation
@testable import DevHubCore

@Suite("CodexAdapter")
struct CodexAdapterTests {

    let adapter = CodexAdapter()

    @Test("identity matches spec-verified path")
    func identity() {
        #expect(adapter.toolId == "codex")
        #expect(adapter.executablePath == "/Applications/ChatGPT.app/Contents/Resources/codex")
        #expect(adapter.requiresPTY == true)
    }

    @Test("capabilities: positional + resume; NO system-prompt-file")
    func capabilities() {
        #expect(adapter.capabilities.contains(.canInjectPositional))
        #expect(adapter.capabilities.contains(.canResume))
        #expect(!adapter.capabilities.contains(.canInjectSystemPrompt))
        #expect(!adapter.capabilities.contains(.canOpenGUI))
    }

    @Test("launchNew without memory: bare codex")
    func launchNewNoMemory() async throws {
        let spec = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: nil, sessionId: nil, tool: nil
        ))
        #expect(spec.executable == "/Applications/ChatGPT.app/Contents/Resources/codex")
        #expect(spec.arguments == [])
    }

    @Test("resume without memory: `codex resume <id>`")
    func resumeNoMemory() async throws {
        let spec = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: nil, sessionId: "abc-123", tool: nil
        ))
        #expect(spec.arguments == ["resume", "abc-123"])
    }

    @Test("resume with memory: launcher expands $(cat <memfile>) via placeholder")
    func resumeWithMemory() async throws {
        let spec = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: "/tmp/inj.md", sessionId: "abc-123", tool: nil
        ))
        // LauncherScriptBuilder (Task 25) recognizes $__DEVHUB_MEMORY_FILE__<path> and replaces
        // with $(cat '<path>') so memory content never enters argv directly (avoids E2BIG)
        #expect(spec.arguments == ["resume", "abc-123", "$__DEVHUB_MEMORY_FILE__/tmp/inj.md"])
    }
}
