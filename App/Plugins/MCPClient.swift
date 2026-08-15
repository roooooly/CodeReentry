import Foundation
import Darwin
import OSLog
#if canImport(System)
import System
#else
@preconcurrency import SystemPackage
#endif
import MCP
import DevHubCore

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "mcp-client")

private final class MCPHandshakeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false

    func claim() -> Bool {
        lock.withLock {
            guard !resolved else { return false }
            resolved = true
            return true
        }
    }
}

/// 启动一个子进程（command + args + env），把它的 stdin/stdout 包成 swift-sdk 的
/// `StdioTransport(input:output:)` 所需的 FileDescriptor。
///
/// swift-sdk 0.12.1 的 StdioTransport 只接 FileDescriptor，不 spawn 进程；
/// 本类负责 Process 生命周期 + 把 Pipe 端点转成 FileDescriptor。
final class ProcessTransport: @unchecked Sendable {
    let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe

    /// 子进程 stdin 对应的 FileDescriptor（写入端 → 传给 StdioTransport 的 output）
    /// 子进程 stdout 对应的 FileDescriptor（读取端 → 传给 StdioTransport 的 input）
    let transportInput: FileDescriptor  // 读子进程 stdout
    let transportOutput: FileDescriptor  // 写子进程 stdin
    var onTermination: (@Sendable (Int32) -> Void)?

    init(command: String, args: [String], env: [String: String]?) throws {
        process = Process()
        let expanded = (command as NSString).expandingTildeInPath
        if expanded.contains("/") {
            process.executableURL = URL(fileURLWithPath: expanded)
            process.arguments = args
        } else {
            // Finder 启动的 GUI 不会做 shell PATH 解析；通过 env 启动裸命令（如 npx）。
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [expanded] + args
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = Self.childEnvironment(
            parent: ProcessInfo.processInfo.environment,
            home: home,
            configured: env
        )

        stdinPipe = Pipe()
        stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // FileHandle.availableData blocks. Keep the drain on a GCD worker so an
        // unresponsive server cannot occupy Swift's cooperative executor (or the
        // MainActor inherited from MCPClient.start()).
        let stderrHandle = stderrPipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                logger.warning("MCP server emitted \(chunk.count) stderr bytes (content redacted)")
            }
        }

        // Pipe 的 fileHandleForWriting → FileDescriptor（子进程的 stdin）
        transportOutput = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        // Pipe 的 fileHandleForReading → FileDescriptor（子进程的 stdout）
        transportInput = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        process.terminationHandler = { [weak self] process in
            self?.onTermination?(process.terminationStatus)
        }
    }

    /// 第三方 MCP server 默认只能继承运行所需的最小环境；配置文件中显式声明的
    /// env 仍会覆盖白名单值。这样从 Terminal/Xcode 启动 DevHub 时，父进程里的
    /// API key、token 等不会被无提示传给插件进程。
    static func childEnvironment(
        parent: [String: String],
        home: String,
        configured: [String: String]?
    ) -> [String: String] {
        let inheritedKeys = [
            "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
            "USER", "LOGNAME", "SHELL",
        ]
        var environment = parent.filter { inheritedKeys.contains($0.key) }
        environment["HOME"] = environment["HOME"] ?? home
        let inheritedPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "\(home)/.npm-global/bin", inheritedPath,
        ].joined(separator: ":")
        if let configured { environment.merge(configured) { _, new in new } }
        return environment
    }

    func run() throws {
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    func terminate(gracePeriod: TimeInterval = 0.5) async {
        let processIdentifier = process.processIdentifier
        let descendants = Self.descendantProcessIdentifiers(of: processIdentifier)
        for identifier in descendants.reversed() {
            kill(identifier, SIGTERM)
        }
        if process.isRunning {
            process.terminate()
            if gracePeriod > 0 {
                try? await Task.sleep(
                    nanoseconds: UInt64(gracePeriod * 1_000_000_000)
                )
            }
            if process.isRunning {
                kill(processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        for identifier in descendants where kill(identifier, 0) == 0 {
            kill(identifier, SIGKILL)
        }
        // 只结束进程还不足以保证 SDK 的 read 立即返回：父进程仍持有 Pipe 端点。
        // 显式关闭传输描述符，让超时后的 connect task 确定性退出。
        try? stdinPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
    }

    /// MCP server 常通过 npx/node 再派生子进程。退出时只杀直接 Process 会留下孤儿，
    /// 因此先快照整棵后代树，再从叶子向根发送信号。
    private static func descendantProcessIdentifiers(of root: Int32) -> [Int32] {
        let listing = Process()
        listing.executableURL = URL(fileURLWithPath: "/bin/ps")
        listing.arguments = ["-axo", "pid=,ppid="]
        let output = Pipe()
        listing.standardOutput = output
        listing.standardError = FileHandle.nullDevice
        do {
            try listing.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            listing.waitUntilExit()
            guard listing.terminationStatus == 0 else { return [] }

            var children: [Int32: [Int32]] = [:]
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2,
                      let pid = Int32(fields[0]),
                      let parent = Int32(fields[1]) else { continue }
                children[parent, default: []].append(pid)
            }
            var result: [Int32] = []
            var stack = children[root] ?? []
            var seen: Set<Int32> = []
            while let identifier = stack.popLast() {
                guard seen.insert(identifier).inserted else { continue }
                result.append(identifier)
                stack.append(contentsOf: children[identifier] ?? [])
            }
            return result
        } catch {
            return []
        }
    }
}

struct MCPToolInfo: Identifiable, Sendable, Equatable {
    let serverName: String
    let name: String
    let title: String
    let description: String?
    let inputSchemaJSON: String
    var id: String { "\(serverName).\(name)" }
}

struct MCPToolCallResult: Sendable, Equatable {
    let text: String
    let isError: Bool
}

/// 单个 MCP server 的客户端（§6.3）。
/// 持有 swift-sdk 的 `Client` + `ProcessTransport`；start() 跑重连策略到上限后降级。
@MainActor
final class MCPClient {
    let name: String
    let serverConfig: MCPServerConfig
    let reconnectPolicy: MCPReconnectPolicy
    let handshakeTimeout: TimeInterval

    private(set) var status: MCPClientStatus = .disconnected
    private var sdkClient: Client?
    private var processTransport: ProcessTransport?
    private var intentionallyStopping = false

    init(
        name: String,
        serverConfig: MCPServerConfig,
        reconnectPolicy: MCPReconnectPolicy = MCPReconnectPolicy(),
        handshakeTimeout: TimeInterval = 10
    ) {
        self.name = name
        self.serverConfig = serverConfig
        self.reconnectPolicy = reconnectPolicy
        self.handshakeTimeout = handshakeTimeout
    }

    /// 启动并连接。失败按 reconnectPolicy 重试；耗尽后转 degraded（不抛——spec §9）。
    func start() async {
        intentionallyStopping = false
        var attempt = 0
        while true {
            do {
                status = .connecting
                let transport = try ProcessTransport(
                    command: serverConfig.command,
                    args: serverConfig.args,
                    env: serverConfig.env
                )
                transport.onTermination = { [weak self] exitCode in
                    Task { @MainActor in
                        await self?.handleUnexpectedTermination(exitCode: exitCode)
                    }
                }
                try transport.run()
                processTransport = transport

                let stdio = StdioTransport(input: transport.transportInput, output: transport.transportOutput)
                let client = Client(name: "DevHub", version: "1.0.0")
                try await connect(client: client, stdio: stdio, processTransport: transport)
                sdkClient = client
                status = .connected
                logger.info("MCP server '\(self.name, privacy: .public)' connected")
                return
            } catch {
                await processTransport?.terminate()
                processTransport = nil
                guard let delay = reconnectPolicy.nextDelay(afterAttempt: attempt) else {
                    status = .degraded(reason: "exhausted \(reconnectPolicy.maxAttempts) reconnect attempts")
                    logger.error("MCP server '\(self.name, privacy: .public)' degraded: \(error.localizedDescription, privacy: .public)")
                    return
                }
                logger.warning("MCP server '\(self.name, privacy: .public)' attempt \(attempt) failed, retry in \(delay)s")
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            }
        }
    }

    func disconnect() async {
        intentionallyStopping = true
        let client = sdkClient
        let transport = processTransport
        processTransport = nil
        sdkClient = nil
        status = .disconnected
        await transport?.terminate()
        // 传输端已确定性关闭；SDK 的内部清理不再阻塞 reload 或应用退出。
        if let client { Task { await client.disconnect() } }
    }

    /// 列出该 server 暴露的工具（贡献给 ToolContribution）。
    func listTools() async -> [ToolContribution] {
        guard status.isUsable, let client = sdkClient else { return [] }
        do {
            let result = try await client.listTools()
            return result.tools.map { tool in
                ToolContribution(
                    id: "mcp.\(name).\(tool.name)",
                    title: tool.name,
                    subtitle: tool.description,
                    sourcePluginId: "mcp.\(name)"
                )
            }
        } catch {
            logger.error("listTools 失败 '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    func toolInfos() async -> [MCPToolInfo] {
        guard status.isUsable, let client = sdkClient else { return [] }
        do {
            let result = try await client.listTools()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return result.tools.map { tool in
                let schema = (try? encoder.encode(tool.inputSchema))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return MCPToolInfo(
                    serverName: name,
                    name: tool.name,
                    title: tool.title ?? tool.name,
                    description: tool.description,
                    inputSchemaJSON: schema
                )
            }
        } catch {
            logger.error("listTools 失败 '\(self.name, privacy: .public)': \(error.localizedDescription, privacy: .private(mask: .hash))")
            return []
        }
    }

    func callTool(name toolName: String, argumentsJSON: String) async throws -> MCPToolCallResult {
        guard status.isUsable, let client = sdkClient else {
            throw MCPClientError.notConnected(name)
        }
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        let arguments: [String: Value]?
        if trimmed.isEmpty || trimmed == "{}" {
            arguments = nil
        } else {
            guard let data = trimmed.data(using: .utf8) else {
                throw MCPClientError.invalidArgumentsJSON
            }
            do {
                arguments = try JSONDecoder().decode([String: Value].self, from: data)
            } catch {
                throw MCPClientError.invalidArgumentsJSON
            }
        }
        let result = try await client.callTool(name: toolName, arguments: arguments)
        let rendered = result.content.map(Self.render).joined(separator: "\n")
        return MCPToolCallResult(
            text: String(rendered.prefix(100_000)),
            isError: result.isError ?? false
        )
    }

    private func handleUnexpectedTermination(exitCode: Int32) async {
        guard !intentionallyStopping, status == .connected else { return }
        sdkClient = nil
        processTransport = nil
        status = .disconnected
        logger.warning("MCP server '\(self.name, privacy: .public)' exited unexpectedly (\(exitCode)); reconnecting")
        await start()
    }

    private func connect(
        client: Client,
        stdio: StdioTransport,
        processTransport: ProcessTransport
    ) async throws {
        let timeout = max(0.1, handshakeTimeout)
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        let serverName = name

        // 不能用 structured task group 竞争：某些 transport read 即使取消也不会
        // 立即返回，task group 会等待败方而让“超时”本身永久挂起。一次性 gate
        // 让调用方按时返回；超时分支同时关闭进程与 Pipe，遗留 read 随后自行退出。
        let gate = MCPHandshakeGate()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            Task.detached {
                do {
                    _ = try await client.connect(transport: stdio)
                    if gate.claim() { continuation.resume() }
                } catch {
                    if gate.claim() { continuation.resume(throwing: error) }
                }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                guard gate.claim() else { return }
                await processTransport.terminate()
                continuation.resume(
                    throwing: MCPClientError.handshakeTimedOut(serverName, timeout)
                )
            }
        }
    }

    private static func render(_ content: MCP.Tool.Content) -> String {
        switch content {
        case .text(let text, _, _):
            return text
        case .image(_, let mimeType, _, _):
            return "[image: \(mimeType)]"
        case .audio(_, let mimeType, _, _):
            return "[audio: \(mimeType)]"
        case .resource(let resource, _, _):
            return "[resource: \(String(describing: resource))]"
        case .resourceLink(let uri, let name, let title, _, _, _):
            return "[resource: \(title ?? name) \(uri)]"
        }
    }
}

enum MCPClientError: Error, LocalizedError, Equatable {
    case notConnected(String)
    case invalidArgumentsJSON
    case handshakeTimedOut(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notConnected(let name):
            return String(localized: "MCP server \(name) 尚未连接。")
        case .invalidArgumentsJSON:
            return String(localized: "工具参数必须是 JSON 对象。")
        case .handshakeTimedOut(let name, let timeout):
            return String(localized: "MCP server \(name) 在 \(timeout.formatted()) 秒内未完成握手。")
        }
    }
}
