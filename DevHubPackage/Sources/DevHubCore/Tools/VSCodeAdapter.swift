import Foundation

/// VS Code adapter（§5.2）：GUI app，bundle id `com.microsoft.VSCode`（实测）。
public struct VSCodeAdapter: ToolAdapter {
    public let toolId = "vscode"
    public let executablePath = "/Applications/Visual Studio Code.app"
    public let bundleId = "com.microsoft.VSCode"
    public let requiresPTY = false
    public let capabilities: ToolCapabilities = .canOpenGUI

    public init() {}

    public func launchNew(ctx: LaunchContext) async throws -> ToolInstance {
        return .gui(bundleId: bundleId)
    }

    public func resume(sessionId: String, ctx: LaunchContext) async throws -> ToolInstance {
        return .gui(bundleId: bundleId)
    }
}
