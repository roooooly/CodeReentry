import Foundation
import Testing
@testable import DevHubCore

@Suite("GeminiAdapter")
struct GeminiAdapterTests {
    let adapter = GeminiAdapter()

    @Test("identity and install metadata match the official CLI")
    func identity() {
        #expect(adapter.toolId == "gemini-cli")
        #expect(adapter.executablePath == "gemini")
        #expect(adapter.requiresPTY)
        #expect(adapter.capabilities == [.canResume])
        #expect(adapter.installMethod == .npm)
        #expect(adapter.installCommand == "install -g @google/gemini-cli")
    }

    @Test("new session launches bare gemini")
    func launchNew() async throws {
        let command = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project",
            renderedMemoryFile: nil,
            sessionId: nil,
            tool: nil
        ))

        #expect(command.executable == "gemini")
        #expect(command.arguments.isEmpty)
    }

    @Test("exact session resume uses the full UUID")
    func resume() async throws {
        let command = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project",
            renderedMemoryFile: nil,
            sessionId: "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
            tool: nil
        ))

        #expect(command.arguments == [
            "--resume", "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
        ])
    }

    @Test("persisted launch command remains authoritative")
    func configuredCommand() async throws {
        let tool = Tool(
            name: "Gemini CLI",
            kind: .cli,
            launchCommand: "/opt/tools/gemini --model auto",
            workingDirMode: .projectRoot,
            injectionMode: .cliFlag,
            sortOrder: 0
        )
        let command = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project",
            renderedMemoryFile: nil,
            sessionId: "session-id",
            tool: tool
        ))

        #expect(command.executable == "/opt/tools/gemini")
        #expect(command.arguments == ["--model", "auto", "--resume", "session-id"])
    }
}
