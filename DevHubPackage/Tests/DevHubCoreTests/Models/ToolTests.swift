import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("Tool model")
struct ToolTests {

    @Test("init populates fields and defaults")
    func initFields() {
        let t = Tool(
            id: UUID(),
            name: "codex",
            kind: .cli,
            launchCommand: "/Applications/ChatGPT.app/Contents/Resources/codex",
            workingDirMode: .projectRoot,
            injectionMode: .positionalArg,
            sortOrder: 0
        )
        #expect(t.kind == .cli)
        #expect(t.workingDirMode == .projectRoot)
        #expect(t.customWorkingDir == nil)
        #expect(t.injectMemory == false)
        #expect(t.injectionMode == .positionalArg)
        #expect(t.injectionArgs == nil)
        #expect(t.envVars == [:])
        #expect(t.secretEnvKeys == [])
        #expect(t.mcpServerRef == nil)
        #expect(t.enabled == true)
        // 安装字段默认值
        #expect(t.installCommand == nil)
        #expect(t.installMethod == .manual)
        #expect(t.detectPath == nil)
        #expect(t.downloadURL == nil)
    }

    @Test("install fields persist and decode")
    @MainActor
    func installFieldsPersist() throws {
        let container = try ModelContainer(
            for: Tool.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let t = Tool(
            name: "claude", kind: .cli, launchCommand: "claude",
            workingDirMode: .projectRoot, injectionMode: .cliFlag, sortOrder: 0,
            installCommand: "install -g @anthropic-ai/claude-code",
            installMethod: .npm,
            downloadURL: "https://docs.claude.com/en/docs/claude-code/setup"
        )
        ctx.insert(t)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Tool>()).first!
        #expect(fetched.installCommand == "install -g @anthropic-ai/claude-code")
        #expect(fetched.installMethod == .npm)
        #expect(fetched.downloadURL == "https://docs.claude.com/en/docs/claude-code/setup")
    }

    @Test("secretEnvKeys stores key names only, never values")
    @MainActor
    func secretEnvKeysAreNamesOnly() throws {
        let container = try ModelContainer(
            for: Tool.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let t = Tool(
            name: "claude",
            kind: .cli,
            launchCommand: "claude",
            workingDirMode: .projectRoot,
            injectionMode: .cliFlag,
            sortOrder: 1
        )
        t.secretEnvKeys = ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
        t.envVars = ["LOG_LEVEL": "debug"]
        ctx.insert(t)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Tool>()).first!
        #expect(fetched.secretEnvKeys == ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"])
        #expect(fetched.envVars == ["LOG_LEVEL": "debug"])
    }

    @Test("injectionArgs template format")
    func injectionArgsTemplate() {
        let t = Tool(
            name: "claude",
            kind: .cli,
            launchCommand: "claude",
            workingDirMode: .projectRoot,
            injectionMode: .cliFlag,
            sortOrder: 0
        )
        t.injectionArgs = ["--append-system-prompt-file", "{memory_file}"]
        #expect(t.injectionArgs?.first == "--append-system-prompt-file")
        #expect(t.injectionArgs?.last == "{memory_file}")
    }
}
