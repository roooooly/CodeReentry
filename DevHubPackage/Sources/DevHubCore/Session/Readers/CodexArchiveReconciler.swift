import Foundation

/// §5.3A codex 归档对账。
/// 当 SessionIndex.sourcePath 指向的文件不存在（被 codex 移到 archived_sessions/），
/// 在 sessions/ 和 archived_sessions/ 全局重搜该 toolSessionId，更新 sourcePath。
public struct CodexArchiveReconciler: Sendable {
    public let codexRoot: URL

    public init(codexRoot: URL? = nil) {
        self.codexRoot = codexRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// 返回修正的条目数。
    @discardableResult
    public func reconcile(writer: SessionIndexWriter) async throws -> Int {
        let all = await writer.all()
        var fixed = 0
        for s in all where s.tool == "codex" {
            if FileManager.default.fileExists(atPath: s.sourcePath) { continue }
            // 搜 sessions/ 和 archived_sessions/
            if let newPath = find(sessionId: s.toolSessionId) {
                try await writer.upsert(
                    tool: s.tool, toolSessionId: s.toolSessionId,
                    sourcePath: newPath,
                    projectCwd: s.projectCwd,
                    startedAt: s.startedAt, updatedAt: s.updatedAt,
                    messageCount: s.messageCount, title: s.title, preview: s.preview
                )
                fixed += 1
            }
        }
        return fixed
    }

    private func find(sessionId: String) -> String? {
        for sub in ["sessions", "archived_sessions"] {
            let root = codexRoot.appendingPathComponent(sub, isDirectory: true)
            if FileManager.default.fileExists(atPath: root.path) {
                if let rel = walk(dir: root, sessionId: sessionId) {
                    // 用调用者提供的 codexRoot（未解析 symlink）重建路径，
                    // 保证与写入索引时用的路径形式一致。
                    return root.appendingPathComponent(rel).path
                }
            }
        }
        return nil
    }

    /// 返回相对于 `dir` 的相对路径（仅 lastPathComponent 拼接），避免 symlink 解析差异。
    private func walk(dir: URL, sessionId: String) -> String? {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in contents {
            if let isDir = try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory, isDir {
                if let rel = walk(dir: item, sessionId: sessionId) {
                    return item.lastPathComponent + "/" + rel
                }
            } else if item.pathExtension == "jsonl" {
                let name = item.deletingPathExtension().lastPathComponent
                if name.contains(sessionId) { return item.lastPathComponent }
            }
        }
        return nil
    }
}
