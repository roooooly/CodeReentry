import Foundation
import Testing
@testable import DevHubCore

@Suite("GitHubCopilotAdapter")
struct GitHubCopilotAdapterTests {
    let adapter = GitHubCopilotAdapter()

    @Test("identity and install metadata match the official CLI")
    func identity() {
        #expect(adapter.toolId == "github-copilot")
        #expect(adapter.executablePath == "copilot")
        #expect(adapter.requiresPTY)
        #expect(adapter.capabilities == [.canResume])
        #expect(adapter.installMethod == .brew)
        #expect(adapter.installCommand == "install copilot-cli")
    }

    @Test("new session launches bare copilot")
    func launchNew() async throws {
        let command = try await adapter.buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project",
            renderedMemoryFile: nil,
            sessionId: nil,
            tool: nil
        ))

        #expect(command.executable == "copilot")
        #expect(command.arguments.isEmpty)
    }

    @Test("resume uses the complete persisted session ID")
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
            name: "GitHub Copilot CLI",
            kind: .cli,
            launchCommand: "/opt/tools/copilot --model auto",
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

        #expect(command.executable == "/opt/tools/copilot")
        #expect(command.arguments == ["--model", "auto", "--resume", "session-id"])
    }
}
