import Testing
@testable import DevHubCore

@Suite("GooseAdapter")
struct GooseAdapterTests {
    @Test("declares the official Homebrew install and exact resume contract")
    func metadata() {
        let adapter = GooseAdapter()
        #expect(adapter.toolId == "goose")
        #expect(adapter.executablePath == "goose")
        #expect(adapter.installMethod == .brew)
        #expect(adapter.installCommand == "install block-goose-cli")
        #expect(adapter.capabilities == [.canResume])
    }

    @Test("resume appends the complete session ID to a configured command")
    func resumeCommand() async throws {
        let tool = Tool(
            name: "Goose", kind: .cli,
            launchCommand: "/opt/goose/bin/goose --debug",
            workingDirMode: .projectRoot, injectionMode: .cliFlag, sortOrder: 0
        )
        let command = try await GooseAdapter().buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project", renderedMemoryFile: nil,
            sessionId: "20260820_7", tool: tool
        ))
        #expect(command.executable == "/opt/goose/bin/goose")
        #expect(command.arguments == [
            "--debug", "session", "--resume", "--session-id", "20260820_7"
        ])
    }

    @Test("new session uses the interactive session command")
    func newCommand() async throws {
        let command = try await GooseAdapter().buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project", renderedMemoryFile: nil,
            sessionId: nil, tool: nil
        ))
        #expect(command.executable == "goose")
        #expect(command.arguments == ["session"])
    }
}
