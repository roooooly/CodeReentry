import Testing
import Foundation
@testable import DevHubCore

@Suite("KimiAdapter")
struct KimiAdapterTests {

    let adapter = KimiAdapter()

    @Test("identity")
    func identity() {
        #expect(adapter.toolId == "kimi")
        #expect(adapter.bundleId == "com.moonshot.kimichat")
    }

    @Test("GUI only, no PTY")
    func guiOnly() {
        #expect(adapter.requiresPTY == false)
        #expect(adapter.capabilities == .canOpenGUI)
    }

    @Test("launchNew returns gui instance (no actual NSWorkspace call in test)")
    func launchNewReturnsGUI() async throws {
        let instance = try await adapter.launchNew(ctx: LaunchContext(
            projectPath: "/tmp", renderedMemoryFile: nil, sessionId: nil, tool: nil
        ))
        if case .gui(let bid) = instance {
            #expect(bid == "com.moonshot.kimichat")
        } else {
            Issue.record("expected .gui instance")
        }
    }
}
