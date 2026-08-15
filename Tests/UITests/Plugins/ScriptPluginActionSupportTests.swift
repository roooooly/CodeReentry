import Foundation
import Testing
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("ScriptPluginActionSupport")
@MainActor
struct ScriptPluginActionSupportTests {
    @Test("stableId 会解析为数据库中的真实项目路径")
    func resolvesStableIdToProjectPath() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(
            stableId: "stable-anchor",
            name: "Project",
            path: "/Users/example/Projects/Project"
        )
        context.insert(project)
        try context.save()

        let path = try ScriptPluginActionContextResolver.projectPath(
            selectedProjectStableId: project.stableId,
            modelContext: context
        )

        #expect(path == project.path)
        #expect(path != project.stableId)
    }

    @Test("动作上下文保留当前选中的会话 ID")
    func resolvesSelectedSessionContext() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(stableId: "stable", name: "Project", path: "/tmp/project")
        context.insert(project)
        try context.save()

        let actionContext = try ScriptPluginActionContextResolver.context(
            selectedProjectStableId: project.stableId,
            selectedSessionId: "session-42",
            modelContext: context
        )

        #expect(actionContext.projectPath == project.path)
        #expect(actionContext.selectedSessionId == "session-42")
    }

    @Test("已移除项目不会退化为把 stableId 当路径")
    func missingProjectThrows() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        #expect(throws: ScriptPluginActionContextError.selectedProjectNotFound("missing")) {
            _ = try ScriptPluginActionContextResolver.projectPath(
                selectedProjectStableId: "missing",
                modelContext: container.mainContext
            )
        }
    }

    @Test("非零退出结果同时保留错误和标准输出")
    func formatsFailureResult() {
        let actionTitle = "Deploy"
        let result = ScriptPluginResult(
            exitCode: 7,
            stdout: "fallback",
            stderr: String(repeating: "x", count: 3_000)
        )
        let message = ScriptPluginActionFeedback.resultMessage(actionTitle: actionTitle, result: result)
        let headline = String(localized: "“\(actionTitle)”执行失败（退出码 \(result.exitCode)）。")
        #expect(message.contains(headline))
        #expect(message.contains("\(String(localized: "标准错误"))："))
        #expect(message.contains("\(String(localized: "标准输出"))："))
        #expect(message.contains("fallback"))
        #expect(message.contains("…"))
        #expect(message.count < 2_100)
    }

    @Test("成功结果在有界弹窗消息中显示 stdout")
    func formatsSuccessfulStandardOutput() {
        let actionTitle = "Build"
        let message = ScriptPluginActionFeedback.resultMessage(
            actionTitle: actionTitle,
            result: ScriptPluginResult(
                exitCode: 0,
                stdout: "artifact: " + String(repeating: "a", count: 3_000),
                stderr: ""
            )
        )

        #expect(message.contains(String(localized: "“\(actionTitle)”执行成功。")))
        #expect(message.contains("\(String(localized: "标准输出"))："))
        #expect(message.contains("artifact:"))
        #expect(message.contains("…"))
        #expect(message.count < 2_100)
    }

    @Test("无输出的成功结果仍给出明确反馈")
    func formatsSuccessfulEmptyResult() {
        let actionTitle = "Refresh"
        let message = ScriptPluginActionFeedback.resultMessage(
            actionTitle: actionTitle,
            result: ScriptPluginResult(exitCode: 0, stdout: " \n", stderr: "")
        )

        #expect(message == String(localized: "“\(actionTitle)”执行成功。"))
    }

    @Test("插件失败审计日志只含字节数，不含输出正文")
    func failureAuditSummaryRedactsOutput() {
        let secret = "CANARY_SUPER_SECRET_TOKEN"
        let result = ScriptPluginResult(
            exitCode: 9,
            stdout: "stdout \(secret)",
            stderr: "stderr \(secret)"
        )

        let summary = ScriptPluginActionFeedback.auditSummary(
            actionId: "deploy\nspoof",
            result: result
        )

        #expect(summary.contains("exit=9"))
        #expect(summary.contains("stdoutBytes="))
        #expect(summary.contains("stderrBytes="))
        #expect(summary.contains(secret) == false)
        #expect(summary.contains("\n") == false)
    }

    @Test("插件加载、启用与禁用都会通知命令面板刷新缓存")
    func pluginChangesNotifyCommandCatalog() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-plugin-events-\(UUID().uuidString)", isDirectory: true)
        let pluginDirectory = root.appendingPathComponent("sample", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = #"{"name":"Sample","version":"1.0.0","permissions":["process"],"contributions":{"actions":[{"id":"run","title":"Run","scope":"global","run":"action.js"}]}}"#
        try manifest.write(
            to: pluginDirectory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let center = NotificationCenter()
        let notificationCount = NotificationCounter()
        let token = center.addObserver(
            forName: PluginEnableViewModel.commandsChangedNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount.increment()
        }
        defer { center.removeObserver(token) }

        let permissionsFile = root.appendingPathComponent("permissions.json")
        let viewModel = PluginEnableViewModel(
            registry: ScriptPluginRegistry(root: root),
            store: ScriptPluginPermissionStore(file: permissionsFile),
            notificationCenter: center
        )

        await viewModel.load()
        #expect(notificationCount.value == 1)
        viewModel.prepareEnable(pluginId: "sample")
        await viewModel.confirmEnable(decision: .accepted)
        #expect(notificationCount.value == 2)
        await viewModel.disable(pluginId: "sample")
        #expect(notificationCount.value == 3)
    }

    @Test("撤销权限写入失败时 UI 保持启用且不发布假刷新")
    func failedDisableKeepsEnabledState() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-plugin-revoke-\(UUID().uuidString)", isDirectory: true)
        let pluginDirectory = root.appendingPathComponent("sample", isDirectory: true)
        let stateDirectory = root.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = #"{"name":"Sample","version":"1.0.0","permissions":["process"],"contributions":{"actions":[{"id":"run","title":"Run","scope":"global","run":"action.js"}]}}"#
        try manifest.write(
            to: pluginDirectory.appendingPathComponent("manifest.json"),
            atomically: true,
            encoding: .utf8
        )

        let center = NotificationCenter()
        let notificationCount = NotificationCounter()
        let token = center.addObserver(
            forName: PluginEnableViewModel.commandsChangedNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount.increment()
        }
        defer { center.removeObserver(token) }

        let store = ScriptPluginPermissionStore(
            file: stateDirectory.appendingPathComponent("permissions.json")
        )
        let viewModel = PluginEnableViewModel(
            registry: ScriptPluginRegistry(root: root),
            store: store,
            notificationCenter: center
        )

        await viewModel.load()
        viewModel.prepareEnable(pluginId: "sample")
        await viewModel.confirmEnable(decision: .accepted)
        #expect(viewModel.enabledIds.contains("sample"))
        #expect(notificationCount.value == 2)

        try FileManager.default.removeItem(at: stateDirectory)
        try Data("blocking-file".utf8).write(to: stateDirectory)

        await viewModel.disable(pluginId: "sample")

        #expect(viewModel.enabledIds.contains("sample"))
        #expect(viewModel.loadError?.hasPrefix(String(localized: "无法撤销插件权限：")) == true)
        #expect(notificationCount.value == 2)
        #expect(await store.isConfirmed(pluginId: "sample"))
    }
}

private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
