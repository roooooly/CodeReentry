import Foundation
import AppKit
import DevHubCore
@testable import DevHub

// MARK: - Mock ToolAdapter（protocol，可直接实现；状态用 NSLock 保护以满足 Sendable）

final class MockToolAdapter: ToolAdapter, @unchecked Sendable {
    let toolId: String
    let executablePath: String
    let requiresPTY: Bool
    let capabilities: ToolCapabilities

    /// 返回 .cli 时使用的 launchScriptPath（测试可控）。默认 "/tmp/mock-launcher.sh"。
    var stubbedLauncherPath: String = "/tmp/mock-launcher.sh"
    /// 返回 .gui 时使用的 bundleId（模拟真实 adapter 的 bundleId）。
    var stubbedBundleId: String?
    /// 若设置，launchNew/resume 抛此错误。
    var stubbedError: (any Error)?

    private let lock = NSLock()
    private var _lastLaunchNewCtx: LaunchContext?
    private var _lastResumeCtx: LaunchContext?
    private var _lastResumeSessionId: String?
    private var _launchNewCount = 0
    private var _resumeCount = 0

    init(toolId: String, executablePath: String, requiresPTY: Bool, capabilities: ToolCapabilities) {
        self.toolId = toolId
        self.executablePath = executablePath
        self.requiresPTY = requiresPTY
        self.capabilities = capabilities
    }

    var lastLaunchNewCtx: LaunchContext? { lock.withLock { _lastLaunchNewCtx } }
    var lastResumeCtx: LaunchContext? { lock.withLock { _lastResumeCtx } }
    var lastResumeSessionId: String? { lock.withLock { _lastResumeSessionId } }
    var launchNewCount: Int { lock.withLock { _launchNewCount } }
    var resumeCount: Int { lock.withLock { _resumeCount } }

    func launchNew(ctx: LaunchContext) async throws -> ToolInstance {
        lock.withLock { _lastLaunchNewCtx = ctx; _launchNewCount += 1 }
        if let e = stubbedError { throw e }
        return requiresPTY ? .cli(launchScriptPath: stubbedLauncherPath) : .gui(bundleId: stubbedBundleId ?? "test.\(toolId)")
    }

    func resume(sessionId: String, ctx: LaunchContext) async throws -> ToolInstance {
        lock.withLock {
            _lastResumeCtx = ctx; _lastResumeSessionId = sessionId; _resumeCount += 1
        }
        if let e = stubbedError { throw e }
        return requiresPTY ? .cli(launchScriptPath: stubbedLauncherPath) : .gui(bundleId: stubbedBundleId ?? "test.\(toolId)")
    }
}

// MARK: - Mock GUIAppLauncherWorkspace（Core 的 GUIAppLauncher 通过此 protocol 注入）

final class MockGUIWorkspace: GUIAppLauncherWorkspace, @unchecked Sendable {
    private let lock = NSLock()
    private var _lastBundleId: String?
    private var _lastOpenedURL: URL?

    var lastBundleId: String? { lock.withLock { _lastBundleId } }
    var lastOpenedURL: URL? { lock.withLock { _lastOpenedURL } }

    func openApplication(bundleId: String, configuration: NSWorkspace.OpenConfiguration) async throws {
        lock.withLock { _lastBundleId = bundleId }
    }

    func open(_ url: URL) async throws {
        lock.withLock { _lastOpenedURL = url }
    }
}

// MARK: - 内存型 MemoryStore 工厂：返回一个 projectRoot 指向临时目录的 MemoryStore，
//           内容可控。用于 ToolsTab / MemoryTab / SessionsTab 测试。

enum TestMemoryFactory {
    /// 创建临时项目目录并写入 context.md / last-session-summary.md（可选）。
    /// 返回 (factory, projectRootPath)。factory 接收 path 参数但忽略，始终用同一个 store。
    static func make(contextMd: String, summaryMd: String? = nil) throws -> (factory: (String) -> MemoryStore, rootPath: String) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-mem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let memDir = tmp.appendingPathComponent(".devhub").appendingPathComponent("memory")
        try FileManager.default.createDirectory(at: memDir, withIntermediateDirectories: true)
        try contextMd.write(to: memDir.appendingPathComponent("context.md"), atomically: true, encoding: .utf8)
        if let s = summaryMd {
            try s.write(to: memDir.appendingPathComponent("last-session-summary.md"), atomically: true, encoding: .utf8)
        }
        let store = MemoryStore(projectRoot: tmp)
        // factory 忽略入参 path，恒返回同一 store（测试只关心一个项目）
        return ({ _ in store }, tmp.path)
    }
}
