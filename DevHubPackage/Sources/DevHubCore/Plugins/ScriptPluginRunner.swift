import Foundation
import Darwin
import OSLog

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "script-plugin-runner")

/// Process and pipe APIs block their calling thread. Wrapping the references as
/// unchecked Sendable lets the blocking work live on a GCD worker instead of
/// starving Swift's cooperative executor (and the timeout task running on it).
private final class ScriptPluginBlockingReference<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

/// Rail C action 执行结果（§6.4）。
public struct ScriptPluginResult: Sendable, Equatable {
    public let exitCode: Int
    public let stdout: String
    public let stderr: String

    public init(exitCode: Int, stdout: String, stderr: String) {
        self.exitCode = exitCode; self.stdout = stdout; self.stderr = stderr
    }

    public var succeeded: Bool { exitCode == 0 }
}

/// 传给 action.js 的 JSON 上下文（§6.4）。
public struct ScriptPluginContext: Sendable, Encodable {
    public let projectPath: String?
    public let selectedSessionId: String?
    public let env: [String: String]

    public init(projectPath: String?, selectedSessionId: String?, env: [String: String] = [:]) {
        self.projectPath = projectPath
        self.selectedSessionId = selectedSessionId
        self.env = env
    }
}

/// 执行 Rail C action.js（§6.4）。用 Process + Node/AppleScript（按文件扩展名选 runner）。
/// 输入 JSON 上下文经 stdin 传入；stdout（JSON）反馈结果。
///
/// 权限门控（§6.4 首次启用确认）：若注入了 `permissionStore` 且 action 要求的权限非空，
/// run() 会先校验"用户已确认的权限 ⊇ 当前要求"，否则 throw `notConfirmed`。
/// store 为 nil 时不卡门控（兼容无注入场景）。
public struct ScriptPluginRunner: Sendable {

    public static let defaultTimeout: TimeInterval = 30
    public static let maximumTimeout: TimeInterval = 300
    public static let defaultMaximumOutputBytes = 1_048_576

    /// 决定用哪个解释器跑脚本（按扩展名）。调用方仍可显式注入以覆盖默认选择。
    public var interpreterFor: @Sendable (URL) -> (executable: String, args: [String])

    /// 权限确认存储。nil = 不卡门控（测试或无权限要求的场景）。
    public let permissionStore: ScriptPluginPermissionStore?

    /// 每个 action 的硬超时与单路输出上限，防止失控插件永久挂起或耗尽内存。
    public let timeout: TimeInterval
    public let maximumOutputBytes: Int
    public let currentAppVersion: String

    public init(
        permissionStore: ScriptPluginPermissionStore? = nil,
        timeout: TimeInterval = Self.defaultTimeout,
        maximumOutputBytes: Int = Self.defaultMaximumOutputBytes,
        currentAppVersion: String = Self.detectedAppVersion,
        interpreterFor: @escaping @Sendable (URL) -> (executable: String, args: [String]) = Self.defaultInterpreter
    ) {
        self.permissionStore = permissionStore
        let safeTimeout = timeout.isFinite && timeout > 0 ? timeout : Self.defaultTimeout
        self.timeout = min(safeTimeout, Self.maximumTimeout)
        self.maximumOutputBytes = max(1, maximumOutputBytes)
        self.currentAppVersion = currentAppVersion
        self.interpreterFor = interpreterFor
    }

    public static var detectedAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    public static let defaultInterpreter: @Sendable (URL) -> (String, [String]) = { script in
        switch script.pathExtension.lowercased() {
        case "scpt", "applescript":
            return ("/usr/bin/osascript", [script.path])
        case "sh", "zsh", "command":
            return ("/bin/zsh", [script.path])
        case "bash":
            return ("/bin/bash", [script.path])
        case "js", "mjs", "cjs":
            return ("/usr/bin/env", ["node", script.path])
        default:
            // 兼容原有无扩展名插件：仍按 JavaScript 交给 node。
            return ("/usr/bin/env", ["node", script.path])
        }
    }

    public func run(
        action: ScriptPluginActionRef,
        context: ScriptPluginContext,
        pluginId: String = "",
        requiredPermissions: [ScriptPluginPermission] = []
    ) async throws -> ScriptPluginResult {
        if !ScriptPluginVersion.isCompatible(current: currentAppVersion, minimum: action.minAppVersion) {
            throw ScriptPluginError.incompatibleAppVersion(
                required: action.minAppVersion ?? "",
                current: currentAppVersion
            )
        }

        // 权限门控（§6.4）：有 store 且要求非空权限时，校验已确认状态。
        if let store = permissionStore, !requiredPermissions.isEmpty {
            let confirmed = await store.state(pluginId: pluginId)?.confirmedPermissions ?? []
            if store.needsReconfirm(current: requiredPermissions, confirmed: confirmed) {
                throw ScriptPluginError.notConfirmed
            }
        }

        try validate(context: context, for: action.action.scope)

        let pluginDirectory = action.pluginDir.standardizedFileURL.resolvingSymlinksInPath()
        let script = action.pluginDir
            .appendingPathComponent(action.action.run)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let pluginPrefix = pluginDirectory.path.hasSuffix("/")
            ? pluginDirectory.path
            : pluginDirectory.path + "/"
        guard script.path.hasPrefix(pluginPrefix) else {
            throw ScriptPluginError.scriptOutsidePluginDirectory(script.path)
        }
        guard FileManager.default.isExecutableFile(atPath: script.path) ||
              FileManager.default.fileExists(atPath: script.path) else {
            throw ScriptPluginError.scriptNotFound(script.path)
        }
        let (exec, baseArgs) = interpreterFor(script)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exec)
        process.arguments = baseArgs
        process.currentDirectoryURL = action.pluginDir

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let contextData = try JSONEncoder().encode(context)
        guard contextData.count <= 1_048_576 else {
            throw ScriptPluginError.contextTooLarge
        }

        try process.run()

        // stdout/stderr 必须并行持续排空；顺序 readDataToEndOfFile 会在任一管道写满时死锁。
        let stdoutTask = Task.detached {
            await Self.captureOutputAsync(from: stdoutPipe.fileHandleForReading, limit: maximumOutputBytes)
        }
        let stderrTask = Task.detached {
            await Self.captureOutputAsync(from: stderrPipe.fileHandleForReading, limit: maximumOutputBytes)
        }
        let waitTask = Task.detached { () -> Int in
            await Self.waitForExit(process)
        }
        let timeoutTask = Task<Bool, Never> {
            do {
                try await Task.sleep(for: .seconds(timeout))
            } catch {
                return false
            }
            guard process.isRunning else { return false }
            process.terminate()
            // 不信任插件可能忽略 SIGTERM；短暂宽限后强制结束。
            try? await Task.sleep(for: .milliseconds(250))
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            return true
        }

        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: contextData)
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            if process.isRunning { process.terminate() }
            _ = await waitTask.value
            timeoutTask.cancel()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            throw error
        }

        let code = await withTaskCancellationHandler {
            await waitTask.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        timeoutTask.cancel()
        let timedOut = await timeoutTask.value
        let stdoutCapture = await stdoutTask.value
        let stderrCapture = await stderrTask.value
        if timedOut {
            throw ScriptPluginError.timedOut(seconds: timeout)
        }
        try Task.checkCancellation()

        let stdout = stdoutCapture.rendered
        let stderr = stderrCapture.rendered
        // action.id 来自第三方 manifest，可能包含换行、路径或敏感内容；长期系统日志
        // 只保留执行结果元数据，具体动作仍由当前 UI 反馈。
        logger.info("rail-c action completed exit=\(code)")
        return ScriptPluginResult(exitCode: code, stdout: stdout, stderr: stderr)
    }

    private func validate(context: ScriptPluginContext, for scope: ActionScope) throws {
        switch scope {
        case .project:
            guard let path = context.projectPath, !path.isEmpty else {
                throw ScriptPluginError.missingProjectContext
            }
            guard (path as NSString).isAbsolutePath else {
                throw ScriptPluginError.invalidProjectPath(path)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw ScriptPluginError.invalidProjectPath(path)
            }
        case .session:
            guard let sessionId = context.selectedSessionId, !sessionId.isEmpty else {
                throw ScriptPluginError.missingSessionContext
            }
        case .global:
            break
        }
    }

    private struct CapturedOutput: Sendable {
        let data: Data
        let truncated: Bool

        var rendered: String {
            let value = String(decoding: data, as: UTF8.self)
            return truncated ? value + "\n[output truncated]" : value
        }
    }

    private static func captureOutput(from handle: FileHandle, limit: Int) -> CapturedOutput {
        var captured = Data()
        var truncated = false
        while true {
            do {
                guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
                let remaining = max(0, limit - captured.count)
                if remaining > 0 { captured.append(chunk.prefix(remaining)) }
                if chunk.count > remaining { truncated = true }
            } catch {
                break
            }
        }
        return CapturedOutput(data: captured, truncated: truncated)
    }

    private static func captureOutputAsync(from handle: FileHandle, limit: Int) async -> CapturedOutput {
        let reference = ScriptPluginBlockingReference(handle)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: captureOutput(from: reference.value, limit: limit))
            }
        }
    }

    private static func waitForExit(_ process: Process) async -> Int {
        let reference = ScriptPluginBlockingReference(process)
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                reference.value.waitUntilExit()
                continuation.resume(returning: Int(reference.value.terminationStatus))
            }
        }
    }
}

public enum ScriptPluginError: Error, LocalizedError, Equatable {
    case scriptNotFound(String)
    case scriptOutsidePluginDirectory(String)
    case notConfirmed
    case incompatibleAppVersion(required: String, current: String)
    case missingProjectContext
    case invalidProjectPath(String)
    case missingSessionContext
    case contextTooLarge
    case timedOut(seconds: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .scriptNotFound(let path):
            return String(localized: "插件脚本不存在：\(path)")
        case .scriptOutsidePluginDirectory:
            return String(localized: "插件动作试图运行插件目录之外的脚本，已阻止。")
        case .notConfirmed:
            return String(localized: "此插件尚未确认权限。")
        case .incompatibleAppVersion(let required, let current):
            return String(localized: "插件要求 DevHub \(required) 或更高版本，当前版本为 \(current)。")
        case .missingProjectContext:
            return String(localized: "此动作需要先选择一个项目。")
        case .invalidProjectPath(let path):
            return String(localized: "项目目录无效或已不存在：\(path)")
        case .missingSessionContext:
            return String(localized: "此动作需要先选择一个会话。")
        case .contextTooLarge:
            return String(localized: "插件上下文超过 1 MB 安全上限。")
        case .timedOut(let seconds):
            return String(localized: "插件动作超过 \(Int(seconds)) 秒未完成，已终止。")
        }
    }
}
