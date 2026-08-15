import Foundation

/// 统计 ZCode 会话对应的 artifacts 文件数。只枚举文件名和类型，不读取内容，
/// 保持会话 reader 的只读/最小暴露边界。
public enum ZcodeArtifactCounter {
    public static func count(sourcePath: String, sessionId: String) -> Int {
        let source = URL(fileURLWithPath: sourcePath)
        let cliRoot = source.deletingLastPathComponent().deletingLastPathComponent()
        let directory = cliRoot.appendingPathComponent("artifacts", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                count += 1
            }
        }
        return count
    }
}
