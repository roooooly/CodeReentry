import Foundation
import Darwin
import Testing
import DevHubCore
@testable import DevHub

@Suite("MCP stdio integration")
@MainActor
struct MCPClientIntegrationTests {
    @Test("MCP 子进程只继承白名单环境，显式配置仍可覆盖")
    func childEnvironmentIsSanitized() {
        let environment = ProcessTransport.childEnvironment(
            parent: [
                "PATH": "/custom/bin",
                "HOME": "/Users/example",
                "LANG": "zh_CN.UTF-8",
                "CANARY_PARENT_SECRET": "must-not-leak",
                "OPENAI_API_KEY": "must-not-leak",
            ],
            home: "/Users/example",
            configured: [
                "EXPLICIT_TOKEN": "configured-value",
                "LANG": "en_US.UTF-8",
            ]
        )

        #expect(environment["CANARY_PARENT_SECRET"] == nil)
        #expect(environment["OPENAI_API_KEY"] == nil)
        #expect(environment["EXPLICIT_TOKEN"] == "configured-value")
        #expect(environment["LANG"] == "en_US.UTF-8")
        #expect(environment["PATH"]?.contains("/custom/bin") == true)
    }

    @Test("local stdio server can initialize, list and call a tool", .timeLimit(.minutes(1)))
    func localServerRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-mcp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { _ = try? FileManager.default.removeItem(at: directory) }

        let server = directory.appendingPathComponent("mock-mcp.py")
        let source = #"""
        #!/usr/bin/python3
        import json
        import os
        import sys

        for line in sys.stdin:
            try:
                message = json.loads(line)
            except Exception:
                continue
            method = message.get("method")
            request_id = message.get("id")
            if request_id is None:
                continue
            if method == "initialize":
                result = {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "DevHubTestServer", "version": "1.0.0"}
                }
            elif method == "tools/list":
                result = {"tools": [{
                    "name": "echo",
                    "title": "Echo",
                    "description": "Returns the supplied value",
                    "inputSchema": {
                        "type": "object",
                        "properties": {"value": {"type": "string"}}
                    }
                }]}
            elif method == "tools/call":
                value = message.get("params", {}).get("arguments", {}).get("value", "")
                value += "|" + os.environ.get("DEVHUB_MCP_PARENT_CANARY", "missing")
                value += "|" + os.environ.get("DEVHUB_MCP_EXPLICIT", "missing")
                result = {"content": [{"type": "text", "text": value}], "isError": False}
            elif method == "ping":
                result = {}
            else:
                response = {
                    "jsonrpc": "2.0", "id": request_id,
                    "error": {"code": -32601, "message": "Method not found"}
                }
                print(json.dumps(response), flush=True)
                continue
            print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)
        """#
        try source.write(to: server, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: server.path
        )

        setenv("DEVHUB_MCP_PARENT_CANARY", "must-not-leak", 1)
        defer { unsetenv("DEVHUB_MCP_PARENT_CANARY") }

        let client = MCPClient(
            name: "local-test",
            serverConfig: MCPServerConfig(
                command: server.path,
                args: [],
                env: ["DEVHUB_MCP_EXPLICIT": "configured-value"]
            ),
            reconnectPolicy: MCPReconnectPolicy(maxAttempts: 0, baseDelay: 0)
        )
        await client.start()
        do {
            #expect(client.status == .connected)

            let tools = await client.toolInfos()
            let tool = try #require(tools.first)
            #expect(tool.name == "echo")
            #expect(tool.title == "Echo")

            let result = try await client.callTool(
                name: "echo",
                argumentsJSON: #"{"value":"hello from DevHub"}"#
            )
            #expect(result.text == "hello from DevHub|missing|configured-value")
            #expect(result.isError == false)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    @Test("无响应 server 会超时降级且被强制终止", .timeLimit(.minutes(1)))
    func silentServerTimesOut() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-mcp-tree-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let childPIDFile = directory.appendingPathComponent("child.pid")
        let source = """
        import signal
        import subprocess
        import sys
        import time
        child = subprocess.Popen([
            sys.executable, "-c",
            "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)"
        ])
        with open(sys.argv[1], "w") as handle:
            handle.write(str(child.pid))
            handle.flush()
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(60)
        """
        let client = MCPClient(
            name: "silent-test",
            serverConfig: MCPServerConfig(
                command: "/usr/bin/python3",
                args: ["-c", source, childPIDFile.path]
            ),
            reconnectPolicy: MCPReconnectPolicy(maxAttempts: 0, baseDelay: 0),
            handshakeTimeout: 1
        )

        await client.start()

        guard case .degraded = client.status else {
            Issue.record("无响应 server 应在握手超时后进入 degraded，实际为 \(client.status)")
            return
        }
        let childPIDText = try String(contentsOf: childPIDFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try #require(Int32(childPIDText))
        defer { _ = kill(childPID, SIGKILL) }
        let deadline = ContinuousClock.now + .seconds(2)
        while kill(childPID, 0) == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(kill(childPID, 0) == -1)
    }

    @Test("无响应 server 不会阻塞健康 server 连接", .timeLimit(.minutes(1)))
    func supervisorStartsServersConcurrently() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-mcp-parallel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let healthyServer = directory.appendingPathComponent("healthy.py")
        let healthySource = #"""
        #!/usr/bin/python3
        import json
        import sys
        for line in sys.stdin:
            message = json.loads(line)
            if message.get("method") == "initialize":
                result = {
                    "protocolVersion": "2025-06-18",
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "Healthy", "version": "1.0.0"}
                }
                print(json.dumps({"jsonrpc": "2.0", "id": message["id"], "result": result}), flush=True)
        """#
        try healthySource.write(to: healthyServer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: healthyServer.path
        )

        let silentSource = """
        import signal
        import time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(60)
        """
        let store = MCPConfigStore(directory: directory)
        try store.save(MCPConfig(servers: [
            "a-silent": MCPServerConfig(
                command: "/usr/bin/python3",
                args: ["-c", silentSource]
            ),
            "b-healthy": MCPServerConfig(command: healthyServer.path, args: []),
        ]))
        let supervisor = MCPClientSupervisor(
            configStore: store,
            handshakeTimeout: 4,
            reconnectPolicy: MCPReconnectPolicy(maxAttempts: 0, baseDelay: 0)
        )

        let startTask = Task { await supervisor.startAll() }
        // Keep this below the silent server's four-second handshake timeout,
        // while leaving enough room for a busy CI host to launch Python.
        let deadline = ContinuousClock.now + .milliseconds(3_500)
        var healthyConnected = false
        while ContinuousClock.now < deadline {
            healthyConnected = supervisor.snapshots().contains {
                $0.name == "b-healthy" && $0.status == .connected
            }
            if healthyConnected { break }
            try await Task.sleep(for: .milliseconds(25))
        }

        #expect(healthyConnected)
        await startTask.value
        let snapshots = supervisor.snapshots()
        #expect(snapshots.first(where: { $0.name == "b-healthy" })?.status == .connected)
        guard case .degraded? = snapshots.first(where: { $0.name == "a-silent" })?.status else {
            Issue.record("无响应 server 应独立降级")
            await supervisor.stopAll()
            return
        }
        await supervisor.stopAll()
    }
}
