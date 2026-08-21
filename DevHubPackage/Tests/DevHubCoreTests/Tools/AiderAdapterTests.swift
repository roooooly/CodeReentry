import Foundation
import SwiftData
import Testing
@testable import DevHubCore

@Suite("AiderAdapter")
struct AiderAdapterTests {
    @Test("new launch uses the configured command without restoring history")
    @MainActor
    func buildsNewCommand() async throws {
        let tool = Tool(
            name: "Aider", kind: .cli,
            launchCommand: "/opt/aider/bin/aider --dark-mode",
            workingDirMode: .projectRoot,
            injectionMode: .cliFlag,
            sortOrder: 0
        )
        let command = try await AiderAdapter().buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project",
            renderedMemoryFile: nil,
            sessionId: nil,
            tool: tool
        ))
        #expect(command == CommandSpec(
            executable: "/opt/aider/bin/aider",
            arguments: ["--dark-mode"]
        ))
    }

    @Test("resume restores the project history without passing a synthetic ID")
    @MainActor
    func buildsResumeCommand() async throws {
        let tool = Tool(
            name: "Aider", kind: .cli,
            launchCommand: "aider",
            workingDirMode: .projectRoot,
            injectionMode: .cliFlag,
            sortOrder: 0
        )
        let command = try await AiderAdapter().buildCommand(ctx: LaunchContext(
            projectPath: "/tmp/project",
            renderedMemoryFile: nil,
            sessionId: "/tmp/project",
            tool: tool
        ))
        #expect(command == CommandSpec(
            executable: "aider",
            arguments: ["--restore-chat-history"]
        ))
    }
}
