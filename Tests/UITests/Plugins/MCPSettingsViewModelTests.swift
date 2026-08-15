import Testing
import Foundation
import DevHubCore
@testable import DevHub

@Suite("MCPSettingsViewModel")
@MainActor
struct MCPSettingsViewModelTests {

    func makeStore() throws -> MCPConfigStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcpset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return MCPConfigStore(directory: dir)
    }

    @Test("loadServers 从 store 读取并暴露 serverNames")
    func load() throws {
        let store = try makeStore()
        try store.addServer(name: "fs", command: "npx", args: ["x"], env: nil)
        try store.addServer(name: "git", command: "npx", args: ["y"], env: nil)
        let vm = MCPSettingsViewModel(store: store)
        vm.load()
        #expect(vm.serverNames == ["fs", "git"])
    }

    @Test("load 空配置 → serverNames 为空")
    func loadEmpty() throws {
        let store = try makeStore()
        let vm = MCPSettingsViewModel(store: store)
        vm.load()
        #expect(vm.serverNames.isEmpty)
    }

    @Test("removeServer 委托 store 并刷新")
    func remove() throws {
        let store = try makeStore()
        try store.addServer(name: "fs", command: "npx", args: ["x"], env: nil)
        let vm = MCPSettingsViewModel(store: store)
        vm.load()
        vm.removeServer("fs")
        #expect(vm.serverNames.isEmpty)
    }

    @Test("requestAdd 从 command+args 构造 confirmation gate")
    func requestAddBuildsGate() throws {
        let store = try makeStore()
        let vm = MCPSettingsViewModel(store: store)
        vm.load()
        vm.newName = "myserver"
        vm.newCommand = "npx"
        vm.newArgs = "-y @modelcontextprotocol/server-filesystem /tmp"
        vm.requestAdd()
        let gate = try #require(vm.pendingConfirmation)
        #expect(gate.serverName == "myserver")
        #expect(gate.server.command == "npx")
        #expect(gate.server.args == ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
    }

    @Test("requestAdd preserves quoted arguments without invoking a shell")
    func requestAddParsesQuotedArguments() throws {
        let store = try makeStore()
        let vm = MCPSettingsViewModel(store: store)
        vm.load()
        vm.newName = "fs"
        vm.newCommand = "npx"
        vm.newArgs = #"-y "package with spaces" '/safe path'"#

        vm.requestAdd()

        let gate = try #require(vm.pendingConfirmation)
        #expect(gate.server.args == ["-y", "package with spaces", "/safe path"])
    }

    @Test("confirmAdd accepted → 写入 store + 清 pendingConfirmation")
    func confirmAddAccepted() throws {
        let store = try makeStore()
        let vm = MCPSettingsViewModel(store: store)
        vm.load()
        vm.newName = "s"
        vm.newCommand = "echo"
        vm.newArgs = ""
        vm.requestAdd()
        try vm.confirmAdd(decision: .accepted)
        #expect(vm.pendingConfirmation == nil)
        #expect(vm.serverNames == ["s"])
        // store 落盘
        let cfg = try store.load()
        #expect(cfg.servers["s"]?.command == "echo")
    }

    @Test("confirmAdd declined → 不写入")
    func confirmAddDeclined() throws {
        let store = try makeStore()
        let vm = MCPSettingsViewModel(store: store)
        vm.load()
        vm.newName = "s"
        vm.newCommand = "echo"
        vm.newArgs = ""
        vm.requestAdd()
        try vm.confirmAdd(decision: .declined)
        #expect(vm.pendingConfirmation == nil)
        #expect(vm.serverNames.isEmpty)
    }

    @Test("confirmAdd 无 pendingConfirmation → 不抛")
    func confirmAddNoPending() throws {
        let store = try makeStore()
        let vm = MCPSettingsViewModel(store: store)
        #expect(throws: Never.self) { try vm.confirmAdd(decision: .accepted) }
    }

    @Test("损坏配置进入只读状态并阻止覆盖")
    func invalidConfigBlocksMutations() throws {
        let store = try makeStore()
        let original = Data(#"{"legacyServers":{"important":{"command":"keep-me"}}}"#.utf8)
        try original.write(to: store.configPath, options: .atomic)
        let vm = MCPSettingsViewModel(store: store)

        vm.load()

        #expect(vm.serverNames.isEmpty)
        #expect(vm.configurationLoadError != nil)
        #expect(vm.canModifyConfiguration == false)
        vm.newName = "replacement"
        vm.newCommand = "echo"
        vm.requestAdd()
        #expect(vm.pendingConfirmation == nil)
        vm.removeServer("important")
        #expect(try Data(contentsOf: store.configPath) == original)
    }

    @Test("确认前文件被外部损坏时仍保留原内容")
    func corruptionBetweenLoadAndConfirmationIsPreserved() throws {
        let store = try makeStore()
        let vm = MCPSettingsViewModel(store: store)
        vm.load()
        vm.newName = "safe"
        vm.newCommand = "echo"
        vm.requestAdd()
        let corrupted = Data("{not json".utf8)
        try corrupted.write(to: store.configPath, options: .atomic)

        #expect(throws: Error.self) { try vm.confirmAdd(decision: .accepted) }
        #expect(try Data(contentsOf: store.configPath) == corrupted)
    }
}
