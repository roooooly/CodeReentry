import Testing
import Foundation
@testable import DevHubCore

@Suite("ToolCapabilities")
struct ToolCapabilitiesTests {

    @Test("OptionSet membership works")
    func optionSet() {
        let caps: ToolCapabilities = [.canInjectSystemPrompt, .canResume]
        #expect(caps.contains(.canInjectSystemPrompt))
        #expect(caps.contains(.canResume))
        #expect(!caps.contains(.canInjectPositional))
        #expect(!caps.contains(.canOpenGUI))
    }

    @Test("LaunchContext carries project path + memory file path + sessionId")
    func launchContext() {
        let ctx = LaunchContext(
            projectPath: "/Users/example/Projects/ExampleApp",
            renderedMemoryFile: "/tmp/inj.md",
            sessionId: "abc",
            tool: nil
        )
        #expect(ctx.projectPath == "/Users/example/Projects/ExampleApp")
        #expect(ctx.sessionId == "abc")
    }

    @Test("ToolInstance carries launch script path or open-app descriptor")
    func toolInstance() {
        let cli = ToolInstance.cli(launchScriptPath: "/Users/example/Library/Caches/DevHub/launchers/x.sh")
        if case .cli(let path) = cli { #expect(path.hasSuffix("x.sh")) }
        let gui = ToolInstance.gui(bundleId: "com.microsoft.VSCode")
        if case .gui(let bid) = gui { #expect(bid == "com.microsoft.VSCode") }
    }
}
