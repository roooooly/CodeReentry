import Foundation
import ServiceManagement
import Testing
@testable import DevHub

@Suite("Launch at login service")
@MainActor
struct LaunchAtLoginServiceTests {
    @Test("SMAppService 状态映射为可观察状态")
    func mapsSystemStates() {
        let service = FakeMainAppService(status: .notRegistered)
        let manager = SystemLaunchAtLoginManager(service: service)
        #expect(manager.state == .disabled)

        service.status = .enabled
        #expect(manager.state == .enabled)

        service.status = .requiresApproval
        #expect(manager.state == .requiresApproval)

        service.status = .notFound
        #expect(manager.state == .unavailable)
    }

    @Test("注册后需要系统批准时返回可操作错误")
    func requiresApprovalAfterRegistration() {
        let service = FakeMainAppService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let manager = SystemLaunchAtLoginManager(service: service)

        #expect(throws: LaunchAtLoginError.requiresApproval) {
            try manager.setEnabled(true)
        }
        #expect(service.registerCallCount == 1)
        #expect(manager.state == .requiresApproval)
    }

    @Test("关闭登录项会调用 unregister 并验证最终状态")
    func unregistersEnabledService() throws {
        let service = FakeMainAppService(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let manager = SystemLaunchAtLoginManager(service: service)

        try manager.setEnabled(false)

        #expect(service.unregisterCallCount == 1)
        #expect(manager.state == .disabled)
    }
}

@Suite("DevHub log exporter")
struct DevHubLogExporterTests {
    @Test("固定 argv 仅查询 DevHub subsystem，二次遮罩并以 0600 保存")
    func exportsRedactedLogsWithPrivatePermissions() async throws {
        let rawLine = #"{"subsystem":"io.github.roooooly.devhub","token":"super-secret-token","eventMessage":"Authorization: Bearer abcdefghijklmnop password=hunter2 AKIAIOSFODNN7EXAMPLE"}"# + "\n"
        let runner = CapturingLogCommandRunner(
            result: DevHubLogCommandResult(
                stdout: Data(rawLine.utf8),
                stderr: Data(),
                exitCode: 0
            )
        )
        let exporter = DevHubLogExporter(runner: runner)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-log-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("DevHub.ndjson")

        let result = try await exporter.exportLastSevenDays(to: destination)

        let invocation = try #require(await runner.lastInvocation())
        #expect(invocation.executableURL.path == "/usr/bin/log")
        #expect(invocation.arguments == DevHubLogExporter.arguments)
        #expect(invocation.arguments.contains(#"subsystem == "io.github.roooooly.devhub""#))
        #expect(invocation.arguments.contains("--last"))
        #expect(invocation.arguments.contains("7d"))

        let savedData = try Data(contentsOf: destination)
        let saved = String(decoding: savedData, as: UTF8.self)
        #expect(result.url == destination)
        #expect(result.byteCount == savedData.count)
        #expect(saved.contains("io.github.roooooly.devhub"))
        #expect(saved.contains("<redacted>"))
        #expect(saved.contains("super-secret-token") == false)
        #expect(saved.contains("abcdefghijklmnop") == false)
        #expect(saved.contains("hunter2") == false)
        #expect(saved.contains("AKIAIOSFODNN7EXAMPLE") == false)

        let jsonLine = try #require(saved.split(separator: "\n").first)
        _ = try JSONSerialization.jsonObject(with: Data(jsonLine.utf8))

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(permissions == 0o600)
    }

    @Test("log show 失败时遮罩 stderr 且不创建导出文件")
    func redactsCommandFailure() async throws {
        let runner = CapturingLogCommandRunner(
            result: DevHubLogCommandResult(
                stdout: Data(),
                stderr: Data("token=do-not-leak".utf8),
                exitCode: 64
            )
        )
        let exporter = DevHubLogExporter(runner: runner)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-parent-\(UUID().uuidString)")
            .appendingPathComponent("DevHub.ndjson")

        do {
            _ = try await exporter.exportLastSevenDays(to: destination)
            Issue.record("Expected log command failure")
        } catch let error as DevHubLogExportError {
            guard case .commandFailed(let code, let message) = error else {
                Issue.record("Unexpected log export error: \(error)")
                return
            }
            #expect(code == 64)
            #expect(message.contains("<redacted>"))
            #expect(message.contains("do-not-leak") == false)
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
    }
}

@MainActor
private final class FakeMainAppService: MainAppServiceControlling {
    var status: SMAppService.Status
    var statusAfterRegister: SMAppService.Status = .enabled
    var statusAfterUnregister: SMAppService.Status = .notRegistered
    var registerCallCount = 0
    var unregisterCallCount = 0

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = statusAfterRegister
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = statusAfterUnregister
    }
}

private actor CapturingLogCommandRunner: DevHubLogCommandRunning {
    struct Invocation: Sendable {
        let executableURL: URL
        let arguments: [String]
    }

    private let result: DevHubLogCommandResult
    private var invocation: Invocation?

    init(result: DevHubLogCommandResult) {
        self.result = result
    }

    func run(executableURL: URL, arguments: [String]) async throws -> DevHubLogCommandResult {
        invocation = Invocation(executableURL: executableURL, arguments: arguments)
        return result
    }

    func lastInvocation() -> Invocation? {
        invocation
    }
}
