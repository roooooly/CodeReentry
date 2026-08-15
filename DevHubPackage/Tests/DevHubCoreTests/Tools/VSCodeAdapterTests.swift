import Testing
import Foundation
@testable import DevHubCore

@Suite("VSCodeAdapter")
struct VSCodeAdapterTests {

    let adapter = VSCodeAdapter()

    @Test("identity")
    func identity() {
        #expect(adapter.toolId == "vscode")
        #expect(adapter.bundleId == "com.microsoft.VSCode")
    }

    @Test("GUI only")
    func guiOnly() {
        #expect(adapter.requiresPTY == false)
        #expect(adapter.capabilities == .canOpenGUI)
    }

    @Test("launchNew returns gui instance")
    func launchNewReturnsGUI() async throws {
        let instance = try await adapter.launchNew(ctx: LaunchContext(
            projectPath: "/tmp/P", renderedMemoryFile: nil, sessionId: nil, tool: nil
        ))
        if case .gui(let bid) = instance {
            #expect(bid == "com.microsoft.VSCode")
        } else {
            Issue.record("expected .gui instance")
        }
    }
}
