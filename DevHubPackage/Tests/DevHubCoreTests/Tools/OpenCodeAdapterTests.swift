import Testing
import Foundation
@testable import DevHubCore

@Suite("OpenCodeAdapter")
struct OpenCodeAdapterTests {

    let adapter = OpenCodeAdapter()

    @Test("identity matches CLI form")
    func identity() {
        #expect(adapter.toolId == "opencode")
        #expect(adapter.executablePath == "opencode")
        #expect(adapter.requiresPTY == true)
    }

    @Test("capabilities: positional + resume")
    func capabilities() {
        #expect(adapter.capabilities.contains(.canInjectPositional))
        #expect(adapter.capabilities.contains(.canResume))
    }

    @Test("install metadata: npm install")
    func installMetadata() {
        #expect(adapter.installMethod == .npm)
        #expect(adapter.installCommand == "install -g opencode-ai")
        #expect(adapter.downloadURL != nil)
    }

    @Test("launchNew without memory: bare opencode")
    func launchNewNoMemory() async throws {
        let spec = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: nil, sessionId: nil, tool: nil
        ))
        #expect(spec.executable == "opencode")
        #expect(spec.arguments == [])
    }

    @Test("resume: opencode resume <id>")
    func resumeNoMemory() async throws {
        let spec = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: nil, sessionId: "abc-123", tool: nil
        ))
        #expect(spec.arguments == ["resume", "abc-123"])
    }

    @Test("resume with memory uses launcher placeholder")
    func resumeWithMemory() async throws {
        let spec = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: "/tmp/inj.md", sessionId: "abc-123", tool: nil
        ))
        #expect(spec.arguments == ["resume", "abc-123", "$__DEVHUB_MEMORY_FILE__/tmp/inj.md"])
    }
}
