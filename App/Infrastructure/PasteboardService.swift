import Foundation
import DevHubCore

/// 项目记忆剪贴板注入的可测试边界。
///
/// 生产实现使用 Core 的 `PasteboardHelper`；测试可注入内存记录器，避免改动用户剪贴板。
@MainActor
protocol PasteboardHandling: AnyObject {
    func write(text: String)
    func clearIfUnchanged(after delay: TimeInterval) async
}

extension PasteboardHelper: PasteboardHandling {}
