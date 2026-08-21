import Testing
@testable import DevHubCore

@Suite("ClineAdapter")
struct ClineAdapterTests {
    @Test("declares the official npm install and exact resume contract")
    func metadata() {
        let adapter = ClineAdapter()
        #expect(adapter.toolId == "cline")
        #expect(adapter.executablePath == "cline")
        #expect(adapter.installMethod == .npm)
        #expect(adapter.installCommand == "install -g cline")
        #expect(adapter.capabilities == [.canResume])
    }

    @Test("resume appends the complete session ID to a configured command")
    func resumeCommand() async throws {
        let tool = Tool(
            name: "Cline", kind: .cli,
            launchCommand: "/opt/cline/bin/cline --provider custom",
            workingDirMode: .projectRoot, injectionMode: .cliFlag, sortOrder: 0
        )
        let command = try await ClineAdapter().buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project", renderedMemoryFile: nil,
            sessionId: "session-full-id", tool: tool
        ))

        #expect(command.executable == "/opt/cline/bin/cline")
        #expect(command.arguments == ["--provider", "custom", "--id", "session-full-id"])
    }

    @Test("new session does not invent an injection argument")
    func newCommand() async throws {
        let command = try await ClineAdapter().buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project", renderedMemoryFile: nil,
            sessionId: nil, tool: nil
        ))
        #expect(command.executable == "cline")
        #expect(command.arguments.isEmpty)
    }
}
