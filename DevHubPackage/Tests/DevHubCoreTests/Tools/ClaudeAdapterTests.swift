import Testing
import Foundation
@testable import DevHubCore

@Suite("ClaudeAdapter")
struct ClaudeAdapterTests {

    let adapter = ClaudeAdapter()

    @Test("toolId and executable path are spec-verified")
    func identity() {
        #expect(adapter.toolId == "claude-code")
        #expect(adapter.executablePath == "claude")
        #expect(adapter.requiresPTY == true)
    }

    @Test("capabilities: canInjectSystemPrompt + canResume; NOT positional")
    func capabilities() {
        #expect(adapter.capabilities.contains(.canInjectSystemPrompt))
        #expect(adapter.capabilities.contains(.canResume))
        #expect(!adapter.capabilities.contains(.canInjectPositional))
        #expect(!adapter.capabilities.contains(.canOpenGUI))
    }

    @Test("launchNew without memory: just `claude`")
    func launchNewNoMemory() async throws {
        let spec = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: nil, sessionId: nil, tool: nil
        ))
        #expect(spec.executable == "claude")
        #expect(spec.arguments == [])
    }

    @Test("launchNew with memory: --append-system-prompt-file <path>")
    func launchNewWithMemory() async throws {
        let spec = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: "/tmp/inj.md", sessionId: nil, tool: nil
        ))
        #expect(spec.executable == "claude")
        #expect(spec.arguments == ["--append-system-prompt-file", "/tmp/inj.md"])
    }

    @Test("resume: --resume <id>")
    func resumeNoMemory() async throws {
        let spec = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: nil, sessionId: "abc", tool: nil
        ))
        #expect(spec.arguments == ["--resume", "abc"])
    }

    @Test("resume with memory: --resume <id> --append-system-prompt-file <path>")
    func resumeWithMemory() async throws {
        let spec = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: "/tmp/inj.md", sessionId: "abc", tool: nil
        ))
        #expect(spec.arguments == ["--resume", "abc", "--append-system-prompt-file", "/tmp/inj.md"])
    }

    @Test("launchNew returns .cli launcher path after Task 25 un-stub")
    func launchNewReal() async throws {
        let instance = try await adapter.launchNew(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: nil, sessionId: nil, tool: nil
        ))
        if case .cli(let path) = instance {
            #expect(path.hasSuffix(".sh"))
            #expect(FileManager.default.fileExists(atPath: path))
        } else {
            Issue.record("expected .cli")
        }
    }
}
