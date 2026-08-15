import Testing
import Foundation
@testable import DevHubCore

@Suite("MCPConfigStore")
struct MCPConfigStoreTests {

    func makeTempDir() -> URL {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcptest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("configPath 在传入目录下定位 mcp.json")
    func configPath() throws {
        let dir = makeTempDir()
        let store = MCPConfigStore(directory: dir)
        #expect(store.configPath == dir.appendingPathComponent("mcp.json"))
    }

    @Test("目录不存在时 ensureDirectory 创建目录")
    func ensureDirectory() throws {
        let dir = makeTempDir().appendingPathComponent("nested")
        let store = MCPConfigStore(directory: dir)
        try store.ensureDirectory()
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    @Test("load 解析标准格式（mcpServers wrapper）")
    func loadParses() throws {
        let dir = makeTempDir()
        let json = """
        {"mcpServers":{"filesystem":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/Users/example"]}}}
        """
        try json.write(to: dir.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        let store = MCPConfigStore(directory: dir)
        let cfg = try store.load()
        let server = try #require(cfg.servers["filesystem"])
        #expect(server.command == "npx")
        #expect(server.args == ["-y", "@modelcontextprotocol/server-filesystem", "/Users/example"])
        #expect(server.env == nil)
    }

    @Test("load 文件不存在返回空 servers")
    func loadMissing() throws {
        let dir = makeTempDir()
        let store = MCPConfigStore(directory: dir)
        let cfg = try store.load()
        #expect(cfg.servers.isEmpty)
    }

    @Test("load 损坏 JSON 时抛错，避免覆盖原文件")
    func loadCorruptThrows() throws {
        let dir = makeTempDir()
        try "{not json".write(to: dir.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        let store = MCPConfigStore(directory: dir)
        #expect(throws: Error.self) { _ = try store.load() }
    }

    @Test("已有文件缺少 mcpServers 时拒绝解码")
    func missingServersKeyThrows() throws {
        let dir = makeTempDir()
        try #"{"servers":{}}"#.write(
            to: dir.appendingPathComponent("mcp.json"),
            atomically: true,
            encoding: .utf8
        )
        let store = MCPConfigStore(directory: dir)

        #expect(throws: MCPConfigError.missingServersKey) { _ = try store.load() }
    }

    @Test("已有 mcpServers 为 null 时拒绝解码")
    func nullServersThrows() throws {
        let dir = makeTempDir()
        try #"{"mcpServers":null}"#.write(
            to: dir.appendingPathComponent("mcp.json"),
            atomically: true,
            encoding: .utf8
        )
        let store = MCPConfigStore(directory: dir)

        #expect(throws: Error.self) { _ = try store.load() }
    }

    @Test("mcpServers 字段存在但内容损坏时拒绝降级为空配置")
    func malformedServersFieldThrows() throws {
        let dir = makeTempDir()
        let json = #"{"mcpServers":{"broken":{"command":42,"args":[]}}}"#
        try json.write(to: dir.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        let store = MCPConfigStore(directory: dir)

        #expect(throws: Error.self) { _ = try store.load() }
    }

    @Test("save 写出后可读回（round-trip）")
    func saveRoundTrip() throws {
        let dir = makeTempDir()
        let store = MCPConfigStore(directory: dir)
        var cfg = MCPConfig(servers: [:])
        cfg.servers["fs"] = MCPServerConfig(command: "npx", args: ["x"], env: ["K": "V"])
        try store.save(cfg)
        let reread = try store.load()
        let s = try #require(reread.servers["fs"])
        #expect(s.command == "npx")
        #expect(s.env == ["K": "V"])
    }

    @Test("save 用 mcpServers 作为 JSON key（兼容 Claude Desktop）")
    func saveUsesMcpServersKey() throws {
        let dir = makeTempDir()
        let store = MCPConfigStore(directory: dir)
        try store.save(MCPConfig(servers: ["fs": MCPServerConfig(command: "npx", args: [], env: nil)]))
        let raw = try String(contentsOfFile: store.configPath.path, encoding: .utf8)
        #expect(raw.contains("\"mcpServers\""))
    }

    @Test("损坏的已有文件不能被 save 覆盖")
    func savePreservesInvalidExistingFile() throws {
        let dir = makeTempDir()
        let path = dir.appendingPathComponent("mcp.json")
        let original = Data(#"{"legacyServers":{"important":{"command":"keep-me"}}}"#.utf8)
        try original.write(to: path, options: .atomic)
        let store = MCPConfigStore(directory: dir)

        #expect(throws: Error.self) {
            try store.save(MCPConfig(servers: [
                "replacement": MCPServerConfig(command: "echo", args: [], env: nil)
            ]))
        }
        #expect(try Data(contentsOf: path) == original)
    }

    @Test("损坏的已有文件不能被 add/remove 覆盖")
    func mutationsPreserveInvalidExistingFile() throws {
        let dir = makeTempDir()
        let path = dir.appendingPathComponent("mcp.json")
        let original = Data(#"{"mcpServers":{"broken":{"command":42,"args":[]}}}"#.utf8)
        try original.write(to: path, options: .atomic)
        let store = MCPConfigStore(directory: dir)

        #expect(throws: Error.self) {
            try store.addServer(name: "new", command: "echo", args: [], env: nil)
        }
        #expect(try Data(contentsOf: path) == original)
        #expect(throws: Error.self) { try store.removeServer(name: "broken") }
        #expect(try Data(contentsOf: path) == original)
    }

    @Test("addServer 写入")
    func addServer() throws {
        let dir = makeTempDir()
        let store = MCPConfigStore(directory: dir)
        try store.addServer(name: "fs", command: "npx", args: ["x"], env: nil)
        let cfg = try store.load()
        #expect(cfg.servers["fs"]?.command == "npx")
    }

    @Test("removeServer 删除条目")
    func removeServer() throws {
        let dir = makeTempDir()
        let store = MCPConfigStore(directory: dir)
        try store.addServer(name: "fs", command: "npx", args: [], env: nil)
        try store.removeServer(name: "fs")
        let cfg = try store.load()
        #expect(cfg.servers["fs"] == nil)
    }
}

@Suite("MCPClientStatus")
struct MCPClientStatusTests {
    @Test("degraded 状态 isUsable=false")
    func degradedNotUsable() {
        let s = MCPClientStatus.degraded(reason: "process exited 1")
        #expect(s.isUsable == false)
        #expect(s.localizedDescription.contains("process exited"))
    }

    @Test("connected 状态可用")
    func connectedUsable() {
        #expect(MCPClientStatus.connected.isUsable == true)
    }

    @Test("disconnected/connecting 不可用")
    func intermediateNotUsable() {
        #expect(MCPClientStatus.disconnected.isUsable == false)
        #expect(MCPClientStatus.connecting.isUsable == false)
    }

    @Test("localizedDescription 全状态非空")
    func allHaveDescription() {
        for s in [MCPClientStatus.disconnected, .connecting, .connected, .degraded(reason: "x")] {
            #expect(s.localizedDescription.isEmpty == false)
        }
    }
}
