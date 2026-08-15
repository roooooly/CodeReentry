import Foundation

/// §5.3B 手动触发的会话总结生成（纯本地解析，无 AI 调用）。
/// 取前 N 条 user message 拼成 markdown 摘要，写入 last-session-summary.md。
public enum SummaryExtractor {

    public static func extractSummary(from detail: SessionDetail, maxUserMessages: Int = 5) -> String {
        let userMessages = detail.messages.filter { $0.role == .user }.prefix(maxUserMessages)
        if userMessages.isEmpty {
            return String(localized: "# 会话总结") + "\n\n" + String(localized: "（无用户消息）") + "\n"
        }
        var lines: [String] = []
        lines.append(String(localized: "# 会话总结"))
        lines.append("")
        lines.append(String(localized: "- 工具：\(detail.tool)"))
        lines.append(String(localized: "- 会话 ID：\(detail.toolSessionId)"))
        lines.append(String(localized: "- 开始：\(ISO8601DateFormatter().string(from: detail.startedAt))"))
        lines.append("")
        lines.append(String(localized: "## 用户消息（前 \(userMessages.count) 条）"))
        lines.append("")
        for (i, m) in userMessages.enumerated() {
            lines.append("**\(i + 1).** \(m.content)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
