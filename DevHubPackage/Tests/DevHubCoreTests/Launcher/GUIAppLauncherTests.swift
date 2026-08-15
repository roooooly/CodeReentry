import Testing
import Foundation
import AppKit
@testable import DevHubCore

final class FakeWorkspace: GUIAppLauncherWorkspace, @unchecked Sendable {
    var openedBundleIds: [String] = []
    var openedURLs: [URL] = []
    var openError: Error?
    func openApplication(bundleId: String, configuration: NSWorkspace.OpenConfiguration) async throws {
        openedBundleIds.append(bundleId)
    }
    func open(_ url: URL) async throws {
        if let openError { throw openError }
        openedURLs.append(url)
    }
}

@Suite("GUIAppLauncher")
@MainActor
struct GUIAppLauncherTests {

    @Test("launch VS Code by bundle id")
    func launchVSCode() async throws {
        let workspace = FakeWorkspace()
        let launcher = GUIAppLauncher(workspace: workspace)
        try await launcher.launchApp(bundleId: "com.microsoft.VSCode", projectPath: nil)
        #expect(workspace.openedBundleIds == ["com.microsoft.VSCode"])
    }

    @Test("launch VS Code with project path")
    func launchWithProjectPath() async throws {
        let workspace = FakeWorkspace()
        let launcher = GUIAppLauncher(workspace: workspace)
        try await launcher.launchApp(
            bundleId: "com.microsoft.VSCode",
            projectPath: "/Users/example/Projects/ExampleApp"
        )
        #expect(workspace.openedBundleIds.count == 1)
        #expect(workspace.openedURLs.first?.absoluteString == "vscode://file/Users/example/Projects/ExampleApp")
    }

    @Test("VS Code 项目 URL 打开失败会向调用方抛错")
    func projectURLErrorPropagates() async {
        let workspace = FakeWorkspace()
        workspace.openError = GUIAppLauncherError.openURLEndpointFailed("fixture")
        let launcher = GUIAppLauncher(workspace: workspace)

        await #expect(throws: GUIAppLauncherError.self) {
            try await launcher.launchApp(
                bundleId: "com.microsoft.VSCode",
                projectPath: "/Users/example/Projects/ExampleApp"
            )
        }
    }

    @Test("launch Kimi (no project path concept)")
    func launchKimi() async throws {
        let workspace = FakeWorkspace()
        let launcher = GUIAppLauncher(workspace: workspace)
        try await launcher.launchApp(bundleId: "com.kimi.app", projectPath: nil)
        #expect(workspace.openedBundleIds == ["com.kimi.app"])
    }
}
