import Testing
@testable import DevHubCore

@Suite("PiAdapter")
struct PiAdapterTests {
    @Test("declares the official safe npm install and exact-file resume contract")
    func metadata() {
        let adapter = PiAdapter()
        #expect(adapter.toolId == "pi")
        #expect(adapter.executablePath == "pi")
        #expect(adapter.installMethod == .npm)
        #expect(adapter.installCommand == "install -g --ignore-scripts @earendil-works/pi-coding-agent")
        #expect(adapter.capabilities == [.canResume])
    }

    @Test("resume appends the complete absolute session path")
    func resumeCommand() async throws {
        let tool = Tool(
            name: "Pi", kind: .cli,
            launchCommand: "/opt/pi/bin/pi --offline",
            workingDirMode: .projectRoot, injectionMode: .cliFlag, sortOrder: 0
        )
        let command = try await PiAdapter().buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project", renderedMemoryFile: nil,
            sessionId: "/tmp/pi sessions/session.jsonl", tool: tool
        ))
        #expect(command.executable == "/opt/pi/bin/pi")
        #expect(command.arguments == [
            "--offline", "--session", "/tmp/pi sessions/session.jsonl"
        ])
    }

    @Test("new session adds no recovery argument")
    func newCommand() async throws {
        let command = try await PiAdapter().buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project", renderedMemoryFile: nil,
            sessionId: nil, tool: nil
        ))
        #expect(command.executable == "pi")
        #expect(command.arguments.isEmpty)
    }
}
