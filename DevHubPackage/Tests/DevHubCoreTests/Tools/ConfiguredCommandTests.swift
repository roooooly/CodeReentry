import Testing
import Foundation
@testable import DevHubCore

@Suite("ConfiguredCommand")
struct ConfiguredCommandTests {
    @Test("quoted command is split into executable and fixed argv")
    func quotedCommand() throws {
        let command = try ConfiguredCommand.parse(
            #"/usr/bin/env node "script with spaces.js" --mode=test"#,
            fallbackExecutable: ""
        )

        #expect(command.executable == "/usr/bin/env")
        #expect(command.arguments == ["node", "script with spaces.js", "--mode=test"])
    }

    @Test("existing full path with spaces remains one executable")
    func existingPathWithSpaces() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevHub Tool \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("my tool")
        FileManager.default.createFile(atPath: executable.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: root) }

        let command = try ConfiguredCommand.parse(
            executable.path,
            fallbackExecutable: "",
            appending: ["--safe"]
        )

        #expect(command.executable == executable.path)
        #expect(command.arguments == ["--safe"])
    }

    @Test("malformed quotes are rejected")
    func malformedQuote() {
        #expect(throws: ConfiguredCommandError.unterminatedQuote) {
            try ConfiguredCommand.parse(#"tool "unfinished"#, fallbackExecutable: "")
        }
    }
}

@Suite("GenericToolAdapters")
struct GenericToolAdapterTests {
    @Test("file placeholder enables safe file injection capability")
    func fileInjectionCapability() {
        let adapter = GenericCLIAdapter(
            injectionMode: .cliFlag,
            injectionArguments: ["--context-file", "{memoryFile}"]
        )
        #expect(adapter.capabilities == [.canInjectSystemPrompt])
    }

    @Test("positional injection requires explicit memory placeholder")
    func positionalCapabilityRequiresPlaceholder() {
        let missing = GenericCLIAdapter(
            injectionMode: .positionalArg,
            injectionArguments: ["--prompt"]
        )
        let configured = GenericCLIAdapter(
            injectionMode: .positionalArg,
            injectionArguments: ["--prompt", "{memory}"]
        )
        #expect(missing.capabilities.isEmpty)
        #expect(configured.capabilities == [.canInjectPositional])
    }

    @Test("custom app accepts a bundle identifier")
    func customAppBundleIdentifier() async throws {
        let tool = Tool(
            name: "Preview", kind: .app, launchCommand: "com.example.preview",
            workingDirMode: .projectRoot, injectionMode: .clipboard, sortOrder: 0
        )
        let adapter = GenericGUIAdapter(configuredIdentifier: tool.launchCommand)
        let instance = try await adapter.launchNew(ctx: LaunchContext(
            projectPath: "/tmp", renderedMemoryFile: nil, sessionId: nil, tool: tool
        ))
        #expect(instance == .gui(bundleId: "com.example.preview"))
    }
}
