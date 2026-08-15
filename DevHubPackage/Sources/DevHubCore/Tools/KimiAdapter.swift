import Foundation

/// Kimi adapter（§5.2）：GUI app only，NO CLI injection。
/// bundle id `com.moonshot.kimichat`（实测 /Applications/Kimi.app）。
public struct KimiAdapter: ToolAdapter {
    public let toolId = "kimi"
    public let executablePath = "/Applications/Kimi.app"
    public let bundleId = "com.moonshot.kimichat"
    public let requiresPTY = false
    public let capabilities: ToolCapabilities = .canOpenGUI

    public init() {}

    public func launchNew(ctx: LaunchContext) async throws -> ToolInstance {
        // 真实 NSWorkspace 调用在 GUIAppLauncher (Task 27)；这里返回 descriptor
        return .gui(bundleId: bundleId)
    }

    public func resume(sessionId: String, ctx: LaunchContext) async throws -> ToolInstance {
        // Kimi 是 GUI，无 resume 概念
        return .gui(bundleId: bundleId)
    }
}
