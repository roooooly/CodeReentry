import Testing
import Foundation
@testable import DevHubCore

// MARK: - D1: ScriptPluginManifest

@Suite("ScriptPluginManifest")
struct ScriptPluginManifestTests {

    @Test func parsesMinimalManifest() throws {
        let json = """
        {"name":"Open in iTerm","version":"1.0.0","permissions":["process"],
         "contributions":{"actions":[{"id":"open","title":"在 iTerm 打开","scope":"project","run":"action.js"}]}}
        """
        let m = try JSONDecoder().decode(ScriptPluginManifest.self, from: Data(json.utf8))
        #expect(m.name == "Open in iTerm")
        #expect(m.permissions == [.process])
        #expect(m.contributions.actions.count == 1)
        #expect(m.contributions.actions.first?.run == "action.js")
        #expect(m.contributions.actions.first?.scope == .project)
    }

    @Test func parsesAutomationPermission() throws {
        let json = #"{"name":"x","version":"1","permissions":["automation"],"contributions":{"actions":[]}}"#
        let m = try JSONDecoder().decode(ScriptPluginManifest.self, from: Data(json.utf8))
        #expect(m.permissions == [.automation])
    }

    @Test func rejectsMissingContributions() {
        let json = #"{"name":"x","version":"1","permissions":[]}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ScriptPluginManifest.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsUnknownPermission() {
        let json = #"{"name":"x","version":"1","permissions":["root"],"contributions":{"actions":[]}}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ScriptPluginManifest.self, from: Data(json.utf8))
        }
    }

    @Test func supportsMinAppVersion() throws {
        let json = #"{"name":"x","version":"1","permissions":[],"contributions":{"actions":[]},"minAppVersion":"1.2.0"}"#
        let m = try JSONDecoder().decode(ScriptPluginManifest.self, from: Data(json.utf8))
        #expect(m.minAppVersion == "1.2.0")
    }
}

// MARK: - D2: PluginRegistry

@Suite("ScriptPluginRegistry")
struct ScriptPluginRegistryTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plugins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func createPlugin(name: String, at dir: URL, manifest: String) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifest.write(to: dir.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
    }

    @Test func scansPluginDirAndLoadsManifests() throws {
        let root = try makeTempDir()
        try createPlugin(name: "open-in-iterm", at: root.appendingPathComponent("open-in-iterm"),
                         manifest: #"{"name":"Open in iTerm","version":"1.0.0","permissions":["process"],"contributions":{"actions":[{"id":"o","title":"o","scope":"project","run":"action.js"}]}}"#)
        try createPlugin(name: "empty-actions", at: root.appendingPathComponent("empty-actions"),
                         manifest: #"{"name":"Empty","version":"1","permissions":[],"contributions":{"actions":[]}}"#)
        let registry = ScriptPluginRegistry(root: root)
        let plugins = registry.scan()
        #expect(plugins.count == 2)
        #expect(plugins.contains { $0.id == "open-in-iterm" })
    }

    @Test func skipsDirWithoutManifest() throws {
        let root = try makeTempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notaplugin"), withIntermediateDirectories: true)
        try createPlugin(name: "real", at: root.appendingPathComponent("real"),
                         manifest: #"{"name":"R","version":"1","permissions":[],"contributions":{"actions":[]}}"#)
        let registry = ScriptPluginRegistry(root: root)
        #expect(registry.scan().count == 1)
    }

    @Test func skipsDirWithMalformedManifest() throws {
        let root = try makeTempDir()
        try createPlugin(name: "bad", at: root.appendingPathComponent("bad"), manifest: "{broken")
        let registry = ScriptPluginRegistry(root: root)
        #expect(registry.scan().isEmpty)
    }

    @Test func allActionsAggregated() throws {
        let root = try makeTempDir()
        try createPlugin(name: "multi", at: root.appendingPathComponent("multi"),
                         manifest: #"{"name":"M","version":"1","permissions":[],"contributions":{"actions":[{"id":"a","title":"a","scope":"project","run":"a.js"},{"id":"b","title":"b","scope":"global","run":"b.js"}]}}"#)
        let registry = ScriptPluginRegistry(root: root)
        let actions = registry.allActions()
        #expect(actions.count == 2)
        #expect(actions.contains { $0.action.id == "a" })
    }

    @Test func actionCarriesMinimumAppVersion() throws {
        let root = try makeTempDir()
        try createPlugin(
            name: "future",
            at: root.appendingPathComponent("future"),
            manifest: #"{"name":"Future","version":"1","minAppVersion":"2.4.0","permissions":[],"contributions":{"actions":[{"id":"a","title":"a","scope":"global","run":"a.js"}]}}"#
        )
        let action = try #require(ScriptPluginRegistry(root: root).allActions().first)
        #expect(action.minAppVersion == "2.4.0")
    }
}

@Suite("ScriptPluginVersion")
struct ScriptPluginVersionTests {
    @Test func comparesNumericComponents() {
        #expect(ScriptPluginVersion.isCompatible(current: "0.10.0", minimum: "0.9.0"))
        #expect(ScriptPluginVersion.isCompatible(current: "1.2", minimum: "1.2.0"))
        #expect(!ScriptPluginVersion.isCompatible(current: "1.1.9", minimum: "1.2.0"))
    }

    @Test func rejectsMalformedVersionsConservatively() {
        #expect(!ScriptPluginVersion.isCompatible(current: "dev", minimum: "1.0.0"))
        #expect(!ScriptPluginVersion.isCompatible(current: "1.0.0", minimum: "future"))
        #expect(ScriptPluginVersion.isCompatible(current: "dev", minimum: nil))
    }
}

// MARK: - D3: PermissionStore

@Suite("ScriptPluginPermissionStore")
struct ScriptPluginPermissionStoreTests {

    func makeFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("perm-\(UUID().uuidString).json")
    }

    @Test func unconfirmedPluginNeedsConfirmation() async throws {
        let store = ScriptPluginPermissionStore(file: makeFile())
        #expect(await store.isConfirmed(pluginId: "x") == false)
    }

    @Test func confirmPersistsPermissions() async throws {
        let file = makeFile()
        let store = ScriptPluginPermissionStore(file: file)
        try await store.confirm(pluginId: "x", permissions: [.process, .automation])
        #expect(await store.isConfirmed(pluginId: "x"))
        let state = await store.state(pluginId: "x")
        #expect(state?.confirmedPermissions == [.process, .automation])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func revokeRemovesConfirmation() async throws {
        let store = ScriptPluginPermissionStore(file: makeFile())
        try await store.confirm(pluginId: "x", permissions: [.process])
        try await store.revoke(pluginId: "x")
        #expect(await store.isConfirmed(pluginId: "x") == false)
    }

    @Test func needsReconfirmWhenNewPermissionAdded() {
        let store = ScriptPluginPermissionStore(file: URL(fileURLWithPath: "/tmp/x.json"))
        #expect(store.needsReconfirm(current: [.process, .automation], confirmed: [.process]) == true)
        #expect(store.needsReconfirm(current: [.process], confirmed: [.process, .automation]) == false)
    }

    @Test func persistenceRoundTrip() async throws {
        let file = makeFile()
        let store1 = ScriptPluginPermissionStore(file: file)
        try await store1.confirm(pluginId: "p", permissions: [.network])
        // 新实例从同一文件加载
        let store2 = ScriptPluginPermissionStore(file: file)
        #expect(await store2.isConfirmed(pluginId: "p"))
        #expect(await store2.state(pluginId: "p")?.confirmedPermissions == [.network])
    }

    @Test("落盘失败会抛错且不污染内存确认状态")
    func persistenceFailureRollsBackCache() async throws {
        let file = URL(fileURLWithPath: "/dev/null/permissions.json")
        let store = ScriptPluginPermissionStore(file: file)

        await #expect(throws: Error.self) {
            try await store.confirm(pluginId: "unsafe", permissions: [.process])
        }
        #expect(await store.isConfirmed(pluginId: "unsafe") == false)
    }

    @Test("撤销落盘失败时保留已确认状态")
    func revokeFailureRollsBackCache() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perm-revoke-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("permissions.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ScriptPluginPermissionStore(file: file)
        try await store.confirm(pluginId: "trusted", permissions: [.filesystem])
        try FileManager.default.removeItem(at: directory)
        try Data("blocking-file".utf8).write(to: directory)

        await #expect(throws: Error.self) {
            try await store.revoke(pluginId: "trusted")
        }
        #expect(await store.isConfirmed(pluginId: "trusted"))
    }

    @Test("损坏的权限文件会告警并拒绝被静默覆盖")
    func corruptStateFileIsPreserved() async throws {
        let file = makeFile()
        let original = Data("{not-valid-json".utf8)
        try original.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let store = ScriptPluginPermissionStore(file: file)

        #expect(await store.isConfirmed(pluginId: "new") == false)
        #expect(await store.loadError() != nil)
        await #expect(throws: ScriptPluginPermissionStoreError.self) {
            try await store.confirm(pluginId: "new", permissions: [.process])
        }
        #expect(try Data(contentsOf: file) == original)
    }
}

// MARK: - D4: ScriptPluginRunner

@Suite("ScriptPluginRunner")
struct ScriptPluginRunnerTests {

    @Test func runShellScript() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("railc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("action.sh")
        try "#!/bin/sh\necho \"{\\\"ok\\\":true}\"".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let action = ScriptPluginActionRef(
            pluginId: "p", pluginDir: dir,
            action: ScriptPluginAction(id: "a", title: "A", scope: .project, run: "action.sh"))
        let runner = ScriptPluginRunner()
        let result = try await runner.run(
            action: action,
            context: ScriptPluginContext(projectPath: dir.path, selectedSessionId: nil)
        )
        #expect(result.succeeded)
        #expect(result.stdout.contains("ok"))
    }

    @Test("a plugin closing stdin reports EPIPE without terminating CodeReentry")
    func closedPluginStdinDoesNotRaiseSIGPIPE() async throws {
        let dir = try makeScriptDir()
        let ref = ScriptPluginActionRef(
            pluginId: "p",
            pluginDir: dir,
            action: ScriptPluginAction(id: "a", title: "A", scope: .global, run: "action.sh")
        )
        let runner = ScriptPluginRunner(
            interpreterFor: { _ in
                ("/bin/sh", ["-c", "exec 0<&-; /bin/sleep 1"])
            }
        )
        let context = ScriptPluginContext(
            projectPath: nil,
            selectedSessionId: nil,
            env: ["PAYLOAD": String(repeating: "x", count: 512 * 1_024)]
        )

        do {
            _ = try await runner.run(action: ref, context: context)
            Issue.record("a closed plugin stdin must reject the context write")
        } catch {
            let error = error as NSError
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            #expect(error.domain == NSCocoaErrorDomain)
            #expect(underlying?.domain == NSPOSIXErrorDomain)
            #expect(underlying?.code == Int(EPIPE))
        }
    }

    @Test("默认解释器按扩展名选择，显式注入仍可覆盖")
    func defaultInterpreterSelection() {
        let root = URL(fileURLWithPath: "/tmp/plugin")

        #expect(ScriptPluginRunner.defaultInterpreter(root.appendingPathComponent("action.sh")).0 == "/bin/zsh")
        #expect(ScriptPluginRunner.defaultInterpreter(root.appendingPathComponent("action.zsh")).0 == "/bin/zsh")
        #expect(ScriptPluginRunner.defaultInterpreter(root.appendingPathComponent("action.bash")).0 == "/bin/bash")
        #expect(ScriptPluginRunner.defaultInterpreter(root.appendingPathComponent("action.js")).0 == "/usr/bin/env")
        #expect(ScriptPluginRunner.defaultInterpreter(root.appendingPathComponent("action.js")).1 == ["node", "/tmp/plugin/action.js"])
        #expect(ScriptPluginRunner.defaultInterpreter(root.appendingPathComponent("action.scpt")).0 == "/usr/bin/osascript")

        let overridden = ScriptPluginRunner(interpreterFor: { _ in ("/custom/interpreter", ["--flag"]) })
        #expect(overridden.interpreterFor(root.appendingPathComponent("action.sh")).executable == "/custom/interpreter")
        #expect(overridden.interpreterFor(root.appendingPathComponent("action.sh")).args == ["--flag"])
    }

    @Test func scriptNotFound() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("railc-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let action = ScriptPluginActionRef(
            pluginId: "p", pluginDir: dir,
            action: ScriptPluginAction(id: "a", title: "A", scope: .project, run: "nope.js"))
        let runner = ScriptPluginRunner()
        do {
            _ = try await runner.run(
                action: action,
                context: ScriptPluginContext(projectPath: dir.path, selectedSessionId: nil)
            )
            Issue.record("应抛 scriptNotFound")
        } catch let err as ScriptPluginError {
            #expect(err == .scriptNotFound(dir.appendingPathComponent("nope.js").path))
        } catch {
            Issue.record("意外错误: \(error)")
        }
    }

    // MARK: 权限门控（§6.4 首次启用确认）

    private func makeScriptDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("railc-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("action.sh")
        try "#!/bin/sh\necho ok".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return dir
    }

    private func gateActionRef(pluginId: String = "p", dir: URL) -> ScriptPluginActionRef {
        ScriptPluginActionRef(
            pluginId: pluginId, pluginDir: dir,
            action: ScriptPluginAction(id: "a", title: "A", scope: .project, run: "action.sh"))
    }

    @Test("project scope 拒绝把 stableId 当作路径")
    func projectScopeRejectsStableIdAsPath() async throws {
        let dir = try makeScriptDir()
        let runner = ScriptPluginRunner(interpreterFor: { s in ("/bin/sh", [s.path]) })
        await #expect(throws: ScriptPluginError.invalidProjectPath("stable-project-id")) {
            _ = try await runner.run(
                action: gateActionRef(dir: dir),
                context: ScriptPluginContext(projectPath: "stable-project-id", selectedSessionId: nil)
            )
        }
    }

    @Test("session scope 缺少 session id 时拒绝执行")
    func sessionScopeRequiresSessionId() async throws {
        let dir = try makeScriptDir()
        let ref = ScriptPluginActionRef(
            pluginId: "p",
            pluginDir: dir,
            action: ScriptPluginAction(id: "a", title: "A", scope: .session, run: "action.sh")
        )
        let runner = ScriptPluginRunner(interpreterFor: { s in ("/bin/sh", [s.path]) })
        await #expect(throws: ScriptPluginError.missingSessionContext) {
            _ = try await runner.run(
                action: ref,
                context: ScriptPluginContext(projectPath: nil, selectedSessionId: nil)
            )
        }
    }

    @Test("minAppVersion 高于当前版本时拒绝执行")
    func incompatibleAppVersionIsRejected() async throws {
        let dir = try makeScriptDir()
        let ref = ScriptPluginActionRef(
            pluginId: "p",
            pluginDir: dir,
            action: ScriptPluginAction(id: "a", title: "A", scope: .global, run: "action.sh"),
            minAppVersion: "2.0.0"
        )
        let runner = ScriptPluginRunner(
            currentAppVersion: "1.9.0",
            interpreterFor: { s in ("/bin/sh", [s.path]) }
        )
        await #expect(throws: ScriptPluginError.incompatibleAppVersion(required: "2.0.0", current: "1.9.0")) {
            _ = try await runner.run(
                action: ref,
                context: ScriptPluginContext(projectPath: nil, selectedSessionId: nil)
            )
        }
    }

    @Test("action 脚本不能逃出插件目录")
    func scriptTraversalIsRejected() async throws {
        let dir = try makeScriptDir()
        let escapedPath = dir.deletingLastPathComponent().appendingPathComponent("outside.sh").path
        let ref = ScriptPluginActionRef(
            pluginId: "p",
            pluginDir: dir,
            action: ScriptPluginAction(id: "a", title: "A", scope: .global, run: "../outside.sh")
        )
        let runner = ScriptPluginRunner()
        await #expect(throws: ScriptPluginError.scriptOutsidePluginDirectory(escapedPath)) {
            _ = try await runner.run(
                action: ref,
                context: ScriptPluginContext(projectPath: nil, selectedSessionId: nil)
            )
        }
    }

    @Test("失控 action 超时后被终止")
    func actionTimesOut() async throws {
        let dir = try makeScriptDir()
        let ref = ScriptPluginActionRef(
            pluginId: "p",
            pluginDir: dir,
            action: ScriptPluginAction(id: "a", title: "A", scope: .global, run: "action.sh")
        )
        let runner = ScriptPluginRunner(
            timeout: 0.15,
            interpreterFor: { _ in ("/bin/sleep", ["5"]) }
        )
        let started = ContinuousClock.now
        await #expect(throws: ScriptPluginError.timedOut(seconds: 0.15)) {
            _ = try await runner.run(
                action: ref,
                context: ScriptPluginContext(projectPath: nil, selectedSessionId: nil)
            )
        }
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test("未确认时 throw notConfirmed（requiredPermissions 非空 + store 未 confirm）")
    func throwsWhenNotConfirmed() async throws {
        let dir = try makeScriptDir()
        let store = ScriptPluginPermissionStore(file: Self.tmpPermissionsFile())
        let runner = ScriptPluginRunner(permissionStore: store,
                                        interpreterFor: { s in ("/bin/sh", [s.path]) })
        do {
            _ = try await runner.run(action: gateActionRef(dir: dir),
                                     context: ScriptPluginContext(projectPath: dir.path, selectedSessionId: nil),
                                     pluginId: "p", requiredPermissions: [.filesystem])
            Issue.record("未确认时应抛 notConfirmed")
        } catch let err as ScriptPluginError {
            #expect(err == .notConfirmed)
        }
    }

    @Test("已确认后正常执行")
    func executesWhenConfirmed() async throws {
        let dir = try makeScriptDir()
        let store = ScriptPluginPermissionStore(file: Self.tmpPermissionsFile())
        try await store.confirm(pluginId: "p", permissions: [.filesystem, .network])
        let runner = ScriptPluginRunner(permissionStore: store,
                                        interpreterFor: { s in ("/bin/sh", [s.path]) })
        let result = try await runner.run(action: gateActionRef(dir: dir),
                                          context: ScriptPluginContext(projectPath: dir.path, selectedSessionId: nil),
                                          pluginId: "p", requiredPermissions: [.filesystem])
        #expect(result.succeeded)
        #expect(result.stdout.contains("ok"))
    }

    @Test("requiredPermissions 为空时不卡门控（无 store 或无权限要求）")
    func noGateWhenNoPermissions() async throws {
        let dir = try makeScriptDir()
        // 有 store 但 requiredPermissions=[] → 放行
        let store = ScriptPluginPermissionStore(file: Self.tmpPermissionsFile())
        let runner = ScriptPluginRunner(permissionStore: store,
                                        interpreterFor: { s in ("/bin/sh", [s.path]) })
        let result = try await runner.run(action: gateActionRef(dir: dir),
                                          context: ScriptPluginContext(projectPath: dir.path, selectedSessionId: nil),
                                          pluginId: "p", requiredPermissions: [])
        #expect(result.succeeded)
    }

    @Test("权限列表变化时 throw notConfirmed（needsReconfirm）")
    func throwsWhenPermissionsChanged() async throws {
        let dir = try makeScriptDir()
        let store = ScriptPluginPermissionStore(file: Self.tmpPermissionsFile())
        try await store.confirm(pluginId: "p", permissions: [.filesystem])  // 只确认了 filesystem
        let runner = ScriptPluginRunner(permissionStore: store,
                                        interpreterFor: { s in ("/bin/sh", [s.path]) })
        do {
            _ = try await runner.run(action: gateActionRef(dir: dir),
                                     context: ScriptPluginContext(projectPath: dir.path, selectedSessionId: nil),
                                     pluginId: "p", requiredPermissions: [.filesystem, .automation])  // 新增 automation
            Issue.record("权限变化时应抛 notConfirmed")
        } catch let err as ScriptPluginError {
            #expect(err == .notConfirmed)
        }
    }

    /// 每个测试用独立的 permissions 文件，避免相互污染。
    static func tmpPermissionsFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("perms-\(UUID().uuidString).json")
    }
}
