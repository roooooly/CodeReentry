import Foundation
import AppKit

public protocol GUIAppLauncherWorkspace: Sendable {
    func openApplication(bundleId: String, configuration: NSWorkspace.OpenConfiguration) async throws
    func open(_ url: URL) async throws
}

public struct SystemWorkspace: GUIAppLauncherWorkspace {
    public init() {}

    public func openApplication(bundleId: String, configuration: NSWorkspace.OpenConfiguration) async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            throw GUIAppLauncherError.bundleNotFound(bundleId)
        }
        try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    public func open(_ url: URL) async throws {
        guard NSWorkspace.shared.open(url) else {
            throw GUIAppLauncherError.openURLEndpointFailed(url.path)
        }
    }
}

public enum GUIAppLauncherError: Error, Equatable {
    case bundleNotFound(String)
    case openURLEndpointFailed(String)
}

/// GUI app launcher（§5.2）。
/// **不追踪 PID**——VS Code 多进程架构，open 的 PID 是 /usr/bin/open 短命进程。
@MainActor
public final class GUIAppLauncher {
    private let workspace: GUIAppLauncherWorkspace

    public init(workspace: GUIAppLauncherWorkspace = SystemWorkspace()) {
        self.workspace = workspace
    }

    public func launchApp(bundleId: String, projectPath: String?) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await workspace.openApplication(bundleId: bundleId, configuration: configuration)

        if let path = projectPath, bundleId == "com.microsoft.VSCode" {
            var components = URLComponents()
            components.scheme = "vscode"
            components.host = "file"
            components.path = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let vscodeURL = components.url else {
                throw GUIAppLauncherError.openURLEndpointFailed(path)
            }
            // 打开项目 URL 失败必须反馈给 UI，不能在 App 已启动后静默假成功。
            try await workspace.open(vscodeURL)
        }
    }
}
