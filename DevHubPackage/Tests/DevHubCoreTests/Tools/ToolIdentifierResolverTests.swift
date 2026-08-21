import Testing
@testable import DevHubCore

@Suite("ToolIdentifierResolver")
struct ToolIdentifierResolverTests {
    @Test("session aliases normalize to stable adapter identifiers")
    func aliasesNormalize() {
        #expect(ToolIdentifierResolver.canonical("claude") == "claude-code")
        #expect(ToolIdentifierResolver.canonical("Open Code") == "opencode")
        #expect(ToolIdentifierResolver.canonical("VS Code") == "vscode")
        #expect(ToolIdentifierResolver.canonical("Aider Chat") == "aider")
        #expect(ToolIdentifierResolver.canonical("Cline CLI") == "cline")
        #expect(ToolIdentifierResolver.canonical("Goose CLI") == "goose")
        #expect(ToolIdentifierResolver.canonical("Pi Coding Agent") == "pi")
        #expect(ToolIdentifierResolver.canonical("Gemini") == "gemini-cli")
        #expect(ToolIdentifierResolver.canonical("GitHub Copilot CLI") == "github-copilot")
    }

    @Test("renamed built-in tool remains identifiable from configured executable")
    func renamedToolUsesExecutable() {
        let tool = Tool(
            name: "My preferred assistant",
            kind: .cli,
            launchCommand: "\"/opt/My Tools/claude\" --model sonnet",
            workingDirMode: .projectRoot,
            injectionMode: .cliFlag,
            sortOrder: 0
        )

        #expect(ToolIdentifierResolver.identifier(for: tool) == "claude-code")
        #expect(ToolIdentifierResolver.matches(tool, sessionToolIdentifier: "claude"))
    }

    @Test("renamed Copilot tool remains identifiable from its executable")
    func renamedCopilotUsesExecutable() {
        let tool = Tool(
            name: "Pair programmer",
            kind: .cli,
            launchCommand: "/opt/tools/copilot --model auto",
            workingDirMode: .projectRoot,
            injectionMode: .cliFlag,
            sortOrder: 0
        )

        #expect(ToolIdentifierResolver.identifier(for: tool) == "github-copilot")
    }

    @Test("renamed Cline tool remains identifiable from its executable")
    func renamedClineUsesExecutable() {
        let tool = Tool(
            name: "Terminal agent", kind: .cli,
            launchCommand: "/opt/tools/cline --provider custom",
            workingDirMode: .projectRoot, injectionMode: .cliFlag, sortOrder: 0
        )
        #expect(ToolIdentifierResolver.identifier(for: tool) == "cline")
    }

    @Test("renamed Goose tool remains identifiable from its executable")
    func renamedGooseUsesExecutable() {
        let tool = Tool(
            name: "Local agent", kind: .cli,
            launchCommand: "/opt/tools/goose --debug",
            workingDirMode: .projectRoot, injectionMode: .cliFlag, sortOrder: 0
        )
        #expect(ToolIdentifierResolver.identifier(for: tool) == "goose")
    }

    @Test("renamed Pi tool remains identifiable from its executable")
    func renamedPiUsesExecutable() {
        let tool = Tool(
            name: "Small agent", kind: .cli,
            launchCommand: "/opt/tools/pi --offline",
            workingDirMode: .projectRoot, injectionMode: .cliFlag, sortOrder: 0
        )
        #expect(ToolIdentifierResolver.identifier(for: tool) == "pi")
    }
}
