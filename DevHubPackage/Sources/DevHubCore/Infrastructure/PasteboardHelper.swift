import Foundation
import AppKit

/// §5.2 .clipboard 注入清理。
/// 仅当 changeCount 未变时清空，避免误清用户后续复制。
/// 已知局限：Maccy/Paste 等剪贴板历史工具会即时快照，无法防御。
public final class PasteboardHelper: @unchecked Sendable {

    public private(set) var lastWrittenChangeCount: Int = 0

    public init() {}

    @MainActor
    public func write(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        lastWrittenChangeCount = pb.changeCount
    }

    @MainActor
    public func clearIfUnchanged(after delay: TimeInterval) async {
        if delay > 0 {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        let pb = NSPasteboard.general
        if pb.changeCount == lastWrittenChangeCount {
            pb.clearContents()
        }
    }
}
