import Testing
@testable import DevHubCore

@Suite("ToolIdentifierResolver")
struct ToolIdentifierResolverTests {
    @Test("session aliases normalize to stable adapter identifiers")
    func aliasesNormalize() {
        #expect(ToolIdentifierResolver.canonical("claude") == "claude-code")
        #expect(ToolIdentifierResolver.canonical("Open Code") == "opencode")
        #expect(ToolIdentifierResolver.canonical("VS Code") == "vscode")
        #expect(ToolIdentifierResolver.canonical("Gemini") == "gemini-cli")
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
}
