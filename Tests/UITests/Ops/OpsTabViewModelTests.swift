import Testing
import Foundation
@testable import DevHub
import DevHubCore

@Suite("OpsTabViewModel")
@MainActor
struct OpsTabViewModelTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ops-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func loadShowsMetaAndScripts() async throws {
        let dir = try makeTempDir()
        try #"{"scripts":{"dev":"vite"}}"#.write(toFile: dir.appendingPathComponent("package.json").path, atomically: true, encoding: .utf8)
        let vm = OpsTabViewModel(projectPath: dir)
        await vm.load()
        #expect(vm.meta?.runtime == "node")
        #expect(vm.scripts.contains { $0.name == "dev" })
    }

    @Test func executeAppendsToLog() async throws {
        let dir = try makeTempDir()
        let vm = OpsTabViewModel(projectPath: dir)
        // 直接执行一个 shell 脚本（不依赖 npm 真实可用）。execute 现为流式（fire-and-forget Task）。
        let script = DetectedScript(source: .procfile, name: "say", command: "/bin/echo hi", rawCommand: "echo hi")
        vm.execute(script: script)
        // 流式执行异步追加日志——轮询等待完成（echo 很快）
        let appeared = await pollUntil(timeoutMillis: 2000) {
            vm.log.contains { $0.text.contains("hi") } && !vm.executing
        }
        #expect(appeared)
        #expect(vm.log.contains { $0.stream == .system && $0.text.contains("/bin/echo hi") })
    }

    @Test("用户点击运行只创建待确认项，确认后才执行")
    func executionRequiresConfirmation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let vm = OpsTabViewModel(projectPath: dir)
        let script = DetectedScript(
            source: .procfile,
            name: "confirm-me",
            command: "/bin/echo confirmed",
            rawCommand: "echo confirmed"
        )

        vm.requestExecution(of: script)

        #expect(vm.pendingScript == script)
        #expect(!vm.executing)
        #expect(vm.log.isEmpty)

        vm.confirmExecution(of: script)
        let completed = await pollUntil(timeoutMillis: 2_000) {
            vm.log.contains { $0.text.contains("confirmed") } && !vm.executing
        }
        #expect(completed)
        #expect(vm.pendingScript == nil)
    }

    @Test("stop 中止正在运行的流式脚本")
    func stopTerminatesRunningScript() async throws {
        let dir = try makeTempDir()
        let vm = OpsTabViewModel(projectPath: dir)
        let script = DetectedScript(source: .procfile, name: "sleep",
                                    command: "/bin/sleep 30", rawCommand: "sleep 30")
        vm.execute(script: script)
        // 确认 executing 已置 true
        let started = await pollUntil(timeoutMillis: 1000) { vm.executing }
        #expect(started)
        vm.stop()
        let stopped = await pollUntil(timeoutMillis: 1000) { !vm.executing }
        #expect(stopped)
        #expect(vm.log.contains { $0.stream == .system && $0.text.contains("stopped") })
    }

    @Test("离开 Ops 页调用 stop 后不留下后台进程")
    func pageExitStopTerminatesProcess() async throws {
        let dir = try makeTempDir()
        let runner = LocalProcessRunner()
        let vm = OpsTabViewModel(projectPath: dir, runner: runner)
        let script = DetectedScript(
            source: .procfile,
            name: "long-running",
            command: "/bin/sleep 30",
            rawCommand: "sleep 30"
        )
        vm.execute(script: script)
        let started = await pollUntil(timeoutMillis: 1_000) {
            vm.executing
        }
        #expect(started)

        vm.stop()
        try await Task.sleep(for: .milliseconds(300))
        #expect(!vm.executing)
        let processIsRunning = await runner.currentProcessIsRunning()
        #expect(processIsRunning == false)
    }

    /// 轮询 condition 直到 true 或超时（均在 @MainActor 上，因 VM 是 @MainActor）。
    private func pollUntil(timeoutMillis: Int, condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutMillis) / 1000)
        while Date() < deadline {
            if condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test func searchFiltersLog() async throws {
        let dir = try makeTempDir()
        let vm = OpsTabViewModel(projectPath: dir)
        vm.log.append(LocalProcessRunner.LogLine(stream: .stdout, text: "alpha"))
        vm.log.append(LocalProcessRunner.LogLine(stream: .stdout, text: "beta"))
        vm.search = "alp"
        #expect(vm.filteredLog.count == 1)
        #expect(vm.filteredLog.first?.text == "alpha")
    }

    @Test func clearLogEmpties() async throws {
        let dir = try makeTempDir()
        let vm = OpsTabViewModel(projectPath: dir)
        vm.log.append(LocalProcessRunner.LogLine(stream: .stdout, text: "x"))
        vm.clearLog()
        #expect(vm.log.isEmpty)
    }

    @Test func noManifestsLoadsNothing() async throws {
        let dir = try makeTempDir()
        let vm = OpsTabViewModel(projectPath: dir)
        await vm.load()
        #expect(vm.meta == nil)
        #expect(vm.scripts.isEmpty)
    }
}
