import Foundation

/// Maps persisted, user-editable Tool records back to the stable identifiers
/// used by session readers and adapters.
public enum ToolIdentifierResolver {
    public static func canonical(_ identifier: String) -> String {
        switch identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "claude", "claude-code", "claude code": return "claude-code"
        case "gemini", "gemini cli": return "gemini-cli"
        case "open code": return "opencode"
        case "vs code": return "vscode"
        case "z code": return "zcode"
        case "kimi chat": return "kimi"
        default: return identifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    public static func identifier(for tool: Tool) -> String {
        let name = canonical(tool.name)
        if ["codex", "claude-code", "gemini-cli", "vscode", "zcode", "kimi", "opencode"].contains(name) {
            return name
        }

        // Display names are editable. Keep recognizing built-ins from their
        // configured executable so a rename does not break session resume.
        let rawCommand = tool.launchCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = ((try? ConfiguredCommand.parse(rawCommand, fallbackExecutable: "").executable)
            ?? rawCommand).lowercased()
        if command.contains("zcode.cjs") || command.contains("zcode.app") { return "zcode" }
        if command.contains("chatgpt.app") || command.hasSuffix("/codex") { return "codex" }
        if command.contains("claude") { return "claude-code" }
        if command == "gemini" || command.hasSuffix("/gemini") { return "gemini-cli" }
        if command == "opencode" || command.hasSuffix("/opencode") { return "opencode" }
        if command.contains("visual studio code.app") || command.hasSuffix("/code") { return "vscode" }
        if command.contains("kimi.app") { return "kimi" }
        return name
    }

    public static func matches(_ tool: Tool, sessionToolIdentifier: String) -> Bool {
        identifier(for: tool) == canonical(sessionToolIdentifier)
    }
}
