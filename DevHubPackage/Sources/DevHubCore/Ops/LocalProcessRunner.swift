import Foundation
import Darwin

private struct CapturedProcessOutput: Sendable {
    let data: Data
    let totalBytes: Int

    var wasTruncated: Bool { totalBytes > data.count }
}

private final class ProcessLineAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        lock.withLock {
            pending.append(data)
            var lines: [String] = []
            while let newline = pending.firstIndex(of: 0x0A) {
                var line = pending[..<newline]
                if line.last == 0x0D { line = line.dropLast() }
                lines.append(String(decoding: line, as: UTF8.self))
                pending.removeSubrange(...newline)
            }
            return lines
        }
    }

    func flush() -> String? {
        lock.withLock {
            guard !pending.isEmpty else { return nil }
            defer { pending.removeAll(keepingCapacity: false) }
            return String(decoding: pending, as: UTF8.self)
        }
    }
}

/// Foundation's process and pipe waits are synchronous. Keep those waits off
/// Swift's cooperative executor so timeout tasks can still make progress when
/// several commands are running at once.
private final class LocalProcessBlockingReference<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// 本地进程 spawn + 日志流（§5.6 运维面板）。
/// 与 §5.2 不同：这是 DevHub 自己 spawn 的后台进程（运维脚本），可 terminate；
/// §5.2 不追踪 PID 是针对终端里的交互式 CLI 工具。
public actor LocalProcessRunner {

    /// 防止失控脚本把数百 MB 输出全部留在内存。两路 pipe 仍会持续排空，
    /// 只是每一路最多保留 1 MiB 供 UI 展示。
    private static let outputCaptureLimit = 1_048_576

    public struct LaunchConfig: Sendable {
        public enum Invocation: Sendable, Equatable {
            case argv(executable: String, arguments: [String])
            case shell(command: String)
        }

        public let workingDir: URL
        public let invocation: Invocation
        public let timeout: TimeInterval   // 秒；runToCompletion 用

        public init(workingDir: URL, command: String, timeout: TimeInterval = .infinity) {
            self.workingDir = workingDir; self.invocation = .shell(command: command); self.timeout = timeout
        }

        public init(workingDir: URL, executable: String, arguments: [String],
                    timeout: TimeInterval = .infinity) {
            self.workingDir = workingDir
            self.invocation = .argv(executable: executable, arguments: arguments)
            self.timeout = timeout
        }
    }

    public enum LogStream: String, Sendable { case stdout, stderr, system }

    public struct LogLine: Equatable, Sendable, Identifiable {
        public let id = UUID()
        public let stream: LogStream
        public let text: String
        public let timestamp: Date

        public init(stream: LogStream, text: String, timestamp: Date = Date()) {
            self.stream = stream; self.text = text; self.timestamp = timestamp
        }
    }

    /// 当前流式进程（stream 用）。OpsTab 一次只跑一个脚本，故单实例足够。
    private var currentProcess: Process?

    public init() {}

    /// 同步跑到完成（或 timeout）。返回所有日志行。
    public func runToCompletion(cfg: LaunchConfig) async throws -> [LogLine] {
        let process = Process()
        Self.configure(process, with: cfg)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // 必须并行排空两个 pipe。顺序 readDataToEndOfFile 会在子进程先写满
        // 另一条 pipe 时互相等待，最终把正常命令误判成超时。
        let stdoutTask = Task.detached(priority: .utility) {
            await Self.readPipeAsync(stdoutPipe.fileHandleForReading, limit: Self.outputCaptureLimit)
        }
        let stderrTask = Task.detached(priority: .utility) {
            await Self.readPipeAsync(stderrPipe.fileHandleForReading, limit: Self.outputCaptureLimit)
        }
        let waitTask = Task.detached(priority: .utility) {
            await Self.waitForExit(process)
        }
        let timeoutTask = Task.detached(priority: .utility) { () -> Bool in
            guard cfg.timeout.isFinite else { return false }
            do {
                try await Task.sleep(for: .seconds(cfg.timeout))
            } catch {
                return false
            }
            guard process.isRunning else { return false }
            process.terminate()
            // 给正常 SIGTERM 清理留一点时间；仍不退出则兜底 SIGKILL。
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                // waitTask 可能已完成并取消本任务；超时事实仍应返回 true。
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            return true
        }

        _ = await waitTask.value
        timeoutTask.cancel()
        let timedOut = await timeoutTask.value
        let stdout = await stdoutTask.value
        let stderr = await stderrTask.value

        var lines: [LogLine] = []
        lines.append(contentsOf: Self.logLines(from: stdout.data, stream: .stdout))
        lines.append(contentsOf: Self.logLines(from: stderr.data, stream: .stderr))
        if stdout.wasTruncated {
            lines.append(LogLine(
                stream: .system,
                text: String(localized: "[output truncated] stdout 仅保留前 \(Self.outputCaptureLimit) 字节（总计 \(stdout.totalBytes) 字节）")
            ))
        }
        if stderr.wasTruncated {
            lines.append(LogLine(
                stream: .system,
                text: String(localized: "[output truncated] stderr 仅保留前 \(Self.outputCaptureLimit) 字节（总计 \(stderr.totalBytes) 字节）")
            ))
        }
        if timedOut {
            lines.append(LogLine(stream: .system, text: String(localized: "[timeout] 进程被终止")))
        }

        return lines
    }

    // MARK: - 流式 API（§5.6 stream + terminateCurrent）

    /// 当前是否有流式进程在跑（测试 + UI 用）。
    public func currentProcessIsRunning() -> Bool {
        currentProcess?.isRunning ?? false
    }

    /// 终止当前流式进程（OpsTab 停止按钮）。
    public func terminateCurrent() {
        currentProcess?.terminate()
    }

    /// 流式执行：逐行 yield LogLine（stdout/stderr 经 readabilityHandler 实时回调），
    /// 进程退出时 yield 一条 system 行（含 exit code 或被终止提示）后结束流。
    public func stream(cfg: LaunchConfig) -> AsyncStream<LogLine> {
        AsyncStream { continuation in
            let process = Process()
            Self.configure(process, with: cfg)

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let stdoutAccumulator = ProcessLineAccumulator()
            let stderrAccumulator = ProcessLineAccumulator()
            // Removing a readability handler does not wait for an invocation that
            // is already in flight. Serialize each pipe's read/append/yield cycle
            // with the final drain so termination cannot finish the AsyncStream
            // before a short process's last lines are delivered.
            let stdoutDrainLock = NSLock()
            let stderrDrainLock = NSLock()
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                stdoutDrainLock.withLock {
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil }
                    else {
                        for line in stdoutAccumulator.append(data) {
                            continuation.yield(LogLine(stream: .stdout, text: line))
                        }
                    }
                }
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                stderrDrainLock.withLock {
                    let data = handle.availableData
                    if data.isEmpty { handle.readabilityHandler = nil }
                    else {
                        for line in stderrAccumulator.append(data) {
                            continuation.yield(LogLine(stream: .stderr, text: line))
                        }
                    }
                }
            }

            process.terminationHandler = { proc in
                // Stop future callbacks, then wait for any callback already reading
                // before draining the remaining bytes and finishing the stream.
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                stdoutDrainLock.withLock {
                    let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    for line in stdoutAccumulator.append(remainingStdout) {
                        continuation.yield(LogLine(stream: .stdout, text: line))
                    }
                    if let tail = stdoutAccumulator.flush(), !tail.isEmpty {
                        continuation.yield(LogLine(stream: .stdout, text: tail))
                    }
                }
                stderrDrainLock.withLock {
                    let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    for line in stderrAccumulator.append(remainingStderr) {
                        continuation.yield(LogLine(stream: .stderr, text: line))
                    }
                    if let tail = stderrAccumulator.flush(), !tail.isEmpty {
                        continuation.yield(LogLine(stream: .stderr, text: tail))
                    }
                }
                if proc.terminationStatus == 0 {
                    continuation.yield(LogLine(stream: .system, text: "[exit 0]"))
                } else {
                    continuation.yield(LogLine(stream: .system, text: "[exit \(proc.terminationStatus)]"))
                }
                continuation.finish()
                Task { await self.clearCurrentProcess(identifier: proc.processIdentifier) }
            }

            continuation.onTermination = { @Sendable _ in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                Task { await self.clearCurrentProcess(identifier: process.processIdentifier) }
            }

            do {
                try process.run()
                self.currentProcess = process
                // timeout：到点 terminate（终止会触发 terminationHandler → finish）
                if cfg.timeout.isFinite {
                    Task { [weak process] in
                        try? await Task.sleep(nanoseconds: UInt64(cfg.timeout * 1_000_000_000))
                        guard let p = process, p.isRunning else { return }
                        continuation.yield(LogLine(stream: .system, text: String(localized: "[timeout] 进程被终止")))
                        p.terminate()
                    }
                }
            } catch {
                continuation.yield(LogLine(stream: .system, text: "[error] \(error.localizedDescription)"))
                continuation.finish()
            }
        }
    }

    private func clearCurrentProcess(identifier: Int32) {
        guard currentProcess?.processIdentifier == identifier else { return }
        currentProcess = nil
    }

    private nonisolated static func readPipe(_ handle: FileHandle, limit: Int) -> CapturedProcessOutput {
        var captured = Data()
        var totalBytes = 0
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
                totalBytes += chunk.count
                let remaining = max(0, limit - captured.count)
                if remaining > 0 {
                    captured.append(chunk.prefix(remaining))
                }
            } catch {
                break
            }
        }
        return CapturedProcessOutput(data: captured, totalBytes: totalBytes)
    }

    private nonisolated static func readPipeAsync(
        _ handle: FileHandle,
        limit: Int
    ) async -> CapturedProcessOutput {
        let reference = LocalProcessBlockingReference(handle)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: readPipe(reference.value, limit: limit))
            }
        }
    }

    private nonisolated static func waitForExit(_ process: Process) async -> Int32 {
        let reference = LocalProcessBlockingReference(process)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                reference.value.waitUntilExit()
                continuation.resume(returning: reference.value.terminationStatus)
            }
        }
    }

    private nonisolated static func logLines(from data: Data, stream: LogStream) -> [LogLine] {
        guard !data.isEmpty else { return [] }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { LogLine(stream: stream, text: String($0)) }
    }

    private nonisolated static func configure(_ process: Process, with config: LaunchConfig) {
        switch config.invocation {
        case .shell(let command):
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
        case .argv(let executable, let arguments):
            if executable.contains("/") {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executable] + arguments
            }
        }
        process.currentDirectoryURL = config.workingDir
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let additions = [
            "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin",
            "\(home)/.npm-global/bin"
        ]
        let inherited = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (additions + [inherited]).joined(separator: ":")
        process.environment = environment
    }
}
