import Foundation
import SwiftData
import Testing
@testable import DevHubCore

@Suite("DefaultToolCatalog")
struct DefaultToolCatalogTests {

    @Test("fresh database gets usable built-in tools")
    @MainActor
    func seedsFreshDatabase() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext

        let tools = try DefaultToolCatalog.seedIfNeeded(in: context)

        #expect(tools.map(\.name) == DefaultToolCatalog.defaultNames)
        #expect(tools.filter(\.enabled).count == 11)
        #expect(tools.first { $0.name == "Claude Code" }?.injectionMode == .cliFlag)
        #expect(tools.first { $0.name == "Codex" }?.injectionMode == .positionalArg)
        #expect(tools.first { $0.name == "VS Code" }?.kind == .app)
        #expect(tools.first { $0.name == "OpenCode" }?.launchCommand == "opencode")
        #expect(tools.first { $0.name == "Gemini CLI" }?.launchCommand == "gemini")
        #expect(tools.first { $0.name == "GitHub Copilot CLI" }?.launchCommand == "copilot")
        #expect(tools.first { $0.name == "Aider" }?.launchCommand == "aider")
        #expect(tools.first { $0.name == "Cline" }?.launchCommand == "cline")
        #expect(tools.first { $0.name == "Goose" }?.launchCommand == "goose")
    }

    @Test("automatic seed is idempotent and preserves a customized catalog")
    @MainActor
    func seedIsIdempotent() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let custom = Tool(
            name: "My Tool", kind: .cli, launchCommand: "/usr/bin/true",
            workingDirMode: .projectRoot, injectionMode: .clipboard, sortOrder: 99
        )
        context.insert(custom)
        try context.save()

        _ = try DefaultToolCatalog.seedIfNeeded(in: context)

        let tools = try context.fetch(FetchDescriptor<Tool>())
        #expect(tools.count == 1)
        #expect(tools.first?.name == "My Tool")
    }

    @Test("explicit restore fills missing defaults and binds them to existing projects")
    @MainActor
    func restoreDefaults() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(stableId: "stable", name: "P", path: "/tmp/P")
        context.insert(project)
        try context.save()

        let tools = try DefaultToolCatalog.restoreMissingDefaults(in: context)

        #expect(tools.count == 11)
        #expect(project.tools.count == 11)
    }

    @Test("single-default restore does not revive unrelated deleted tools")
    @MainActor
    func restoresOneDefault() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(stableId: "stable", name: "P", path: "/tmp/P")
        let custom = Tool(
            name: "My Tool", kind: .cli, launchCommand: "/usr/bin/true",
            workingDirMode: .projectRoot, injectionMode: .clipboard, sortOrder: 9
        )
        context.insert(project)
        context.insert(custom)
        try context.save()

        let restored = try DefaultToolCatalog.restoreDefault(named: "Gemini CLI", in: context)
        let tools = try context.fetch(FetchDescriptor<Tool>())

        #expect(restored?.name == "Gemini CLI")
        #expect(restored?.sortOrder == 10)
        #expect(restored?.projects.map(\.stableId) == ["stable"])
        #expect(tools.map(\.name).sorted() == ["Gemini CLI", "My Tool"])
    }
}
