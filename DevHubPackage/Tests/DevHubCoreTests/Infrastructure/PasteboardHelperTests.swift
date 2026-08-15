import Testing
import Foundation
import AppKit
@testable import DevHubCore

@Suite("PasteboardHelper")
struct PasteboardHelperTests {

    @Test("write records changeCount")
    @MainActor
    func writeRecordsChangeCount() {
        let helper = PasteboardHelper()
        let pb = NSPasteboard.general
        let before = pb.changeCount
        helper.write(text: "test memory content")
        #expect(helper.lastWrittenChangeCount == before + 1)
    }

    @Test("clearIfUnchanged does nothing if user copied since write")
    @MainActor
    func clearSkipsIfUserCopied() async throws {
        let helper = PasteboardHelper()
        helper.write(text: "first")
        // 模拟用户复制了别的内容
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("user copied this", forType: .string)
        let before = NSPasteboard.general.changeCount
        await helper.clearIfUnchanged(after: 0.0)  // 立即检查
        #expect(NSPasteboard.general.changeCount == before)  // 没清空
    }

    @Test("clearIfUnchanged clears when changeCount matches")
    @MainActor
    func clearWhenUnchanged() async throws {
        let helper = PasteboardHelper()
        helper.write(text: "to be cleared")
        let beforeClear = NSPasteboard.general.changeCount
        await helper.clearIfUnchanged(after: 0.0)
        // 应该清空（changeCount 增加）
        #expect(NSPasteboard.general.changeCount > beforeClear)
        #expect(NSPasteboard.general.string(forType: .string) == nil || NSPasteboard.general.string(forType: .string) == "")
    }
}
