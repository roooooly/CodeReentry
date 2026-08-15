import Testing
import Foundation
@testable import DevHubCore

@Suite("TerminalController")
@MainActor
struct TerminalControllerTests {

    @Test("buildScript for Terminal.app: write text with quoted path")
    func terminalScript() throws {
        let controller = TerminalController()
        let script = controller.buildAppleScript(
            terminal: .terminal,
            launcherPath: "/tmp/abc 123.sh"
        )
        #expect(script.contains("tell application \"Terminal\""))
        #expect(script.contains("do script"))
        #expect(script.contains("\"/tmp/abc 123.sh\""))
        #expect(!script.contains("api_key"))
    }

    @Test("buildScript for iTerm2: create window + write session text")
    func itermScript() throws {
        let controller = TerminalController()
        let script = controller.buildAppleScript(
            terminal: .iterm2,
            launcherPath: "/tmp/x.sh"
        )
        #expect(script.contains("tell application \"iTerm\""))
        #expect(script.contains("create window"))
        #expect(script.contains("write session"))
        #expect(script.contains("\"/tmp/x.sh\""))
    }

    @Test("buildScript escapes embedded double-quotes in path")
    func escapesDoubleQuotes() throws {
        let controller = TerminalController()
        let script = controller.buildAppleScript(
            terminal: .terminal,
            launcherPath: "/tmp/has\"quote.sh"
        )
        #expect(script.contains("\\\""))
    }

    @Test("terminal enum cases")
    func terminalEnum() {
        #expect(TerminalTarget.allCases.count == 2)
        #expect(TerminalTarget.terminal.appName == "Terminal")
        #expect(TerminalTarget.iterm2.appName == "iTerm")
    }

    @Test("execute records lastLauncherPath for safety audit (spec §5.2)")
    func recordsLauncherPath() async throws {
        let controller = TerminalController()
        // 注入 no-op executor——测试不真的启动 Terminal.app（会触发 TCC 授权阻塞）
        controller.executor = { _ in nil }
        _ = try? await controller.execute(terminal: .terminal, launcherPath: "/tmp/test-hook.sh")
        #expect(controller.lastLauncherPath == "/tmp/test-hook.sh")
    }
}
