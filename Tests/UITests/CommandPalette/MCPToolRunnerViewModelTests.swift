import Foundation
import Testing
import DevHubCore
@testable import DevHub

@Suite("MCPToolRunnerViewModel")
@MainActor
struct MCPToolRunnerViewModelTests {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        func read() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class MockCaller: MCPToolCalling {
        struct Invocation: Equatable {
            let serverName: String
            let toolName: String
            let argumentsJSON: String
        }

        var invocations: [Invocation] = []
        var result = MCPToolCallResult(text: "ok", isError: false)
        var error: Error?

        func callTool(
            serverName: String,
            toolName: String,
            argumentsJSON: String
        ) async throws -> MCPToolCallResult {
            invocations.append(Invocation(
                serverName: serverName,
                toolName: toolName,
                argumentsJSON: argumentsJSON
            ))
            if let error { throw error }
            return result
        }
    }

    private enum TestError: Error, LocalizedError {
        case rejected
        var errorDescription: String? { "server rejected the call" }
    }

    private func makeTool() -> MCPToolInfo {
        MCPToolInfo(
            serverName: "filesystem",
            name: "read_file",
            title: "Read file",
            description: "Reads one file",
            inputSchemaJSON: #"{"type":"object","required":["path"]}"#
        )
    }

    @Test("请求执行只打开确认门，不会提前调用外部 server")
    func requestRequiresConfirmation() {
        let caller = MockCaller()
        let vm = MCPToolRunnerViewModel(tool: makeTool(), caller: caller)
        vm.argumentsJSON = #"{"path":"/tmp/a"}"#

        vm.requestExecution()

        #expect(vm.isConfirming)
        #expect(caller.invocations.isEmpty)
    }

    @Test("参数必须是 JSON 对象，数组或损坏 JSON 都不能进入确认")
    func validatesArgumentsBeforeConfirmation() {
        let caller = MockCaller()
        let vm = MCPToolRunnerViewModel(tool: makeTool(), caller: caller)

        vm.argumentsJSON = "[1, 2]"
        vm.requestExecution()
        #expect(!vm.isConfirming)
        #expect(vm.errorMessage == String(localized: "工具参数必须是 JSON 对象。"))

        vm.errorMessage = nil
        vm.argumentsJSON = "{broken"
        vm.requestExecution()
        #expect(!vm.isConfirming)
        #expect(vm.errorMessage == String(localized: "工具参数必须是 JSON 对象。"))
        #expect(caller.invocations.isEmpty)
    }

    @Test("确认后使用精确 server、tool 与参数调用并展示结果")
    func confirmCallsToolAndStoresResult() async throws {
        let caller = MockCaller()
        caller.result = MCPToolCallResult(text: "file contents", isError: false)
        let vm = MCPToolRunnerViewModel(tool: makeTool(), caller: caller)
        vm.argumentsJSON = #"{ "path": "/tmp/a" }"#
        vm.requestExecution()

        await vm.confirmExecution()

        #expect(caller.invocations == [
            .init(
                serverName: "filesystem",
                toolName: "read_file",
                argumentsJSON: #"{ "path": "/tmp/a" }"#
            )
        ])
        #expect(vm.result == MCPToolCallResult(text: "file contents", isError: false))
        #expect(vm.errorMessage == nil)
        #expect(!vm.isRunning)
        #expect(!vm.isConfirming)
    }

    @Test("server 调用错误会展示且不会留下旧结果")
    func callErrorIsShown() async {
        let caller = MockCaller()
        caller.error = TestError.rejected
        let vm = MCPToolRunnerViewModel(tool: makeTool(), caller: caller)
        vm.result = MCPToolCallResult(text: "stale", isError: false)
        vm.requestExecution()

        await vm.confirmExecution()

        #expect(vm.result == nil)
        #expect(vm.errorMessage == "server rejected the call")
        #expect(caller.invocations.count == 1)
        #expect(!vm.isRunning)
    }

    @Test("MCP 初次加载与配置重载都会通知命令源刷新")
    func supervisorPublishesToolRefreshes() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-command-refresh-\(UUID().uuidString)", isDirectory: true)
        let center = NotificationCenter()
        let supervisor = MCPClientSupervisor(
            configStore: MCPConfigStore(directory: directory),
            notificationCenter: center
        )
        let counter = LockedCounter()
        let token = center.addObserver(
            forName: MCPClientSupervisor.toolsChangedNotification,
            object: nil,
            queue: nil
        ) { _ in
            counter.increment()
        }
        defer { center.removeObserver(token) }

        await supervisor.startAll()
        #expect(counter.read() == 1)

        await supervisor.reload()
        // reload first invalidates stale commands, then publishes the newly
        // connected contribution set after startAll completes.
        #expect(counter.read() == 3)
    }
}
