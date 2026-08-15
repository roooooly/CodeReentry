import Foundation

/// 渲染注入内容（§5.2 §5.3B）。
/// 输出单一字符串——是后续 SecretScanner + 长度截断的输入。
public enum MemoryRenderer {

    public static func render(
        context: String,
        lastSessionSummary: String?,
        gitStatus: GitStatus?
    ) -> String {
        var parts: [String] = []
        parts.append(String(localized: "# 项目记忆"))
        parts.append("")
        parts.append(context.trimmingCharacters(in: .whitespacesAndNewlines))

        if let summary = lastSessionSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            parts.append("")
            parts.append(String(localized: "## 上次会话摘要"))
            parts.append("")
            parts.append(summary)
        }

        if let g = gitStatus {
            parts.append("")
            parts.append(String(localized: "## Git 状态"))
            parts.append("")
            parts.append(String(localized: "- 分支：\(g.branch)"))
            parts.append(String(localized: "- 最近提交：\(g.lastCommitSubject)"))
            parts.append(String(localized: "- \(g.dirtyFileCount) 个未提交文件"))
        }

        return parts.joined(separator: "\n")
    }
}
