import Foundation

/// Converts tool-owned session payloads into reader-facing text.
///
/// Codex can persist launch metadata such as `<environment_context>` as user
/// messages before the person's actual request. Those envelopes are useful to
/// the tool, but they are not conversation titles or previews. DevHub keeps the
/// source logs read-only and filters only the presentation/indexing layer.
public enum SessionDisplayText {
    private static let hiddenEnvelopeTags: Set<String> = [
        "recommended_plugins",
        "environment_context",
        "app-context",
        "skills_instructions",
        "apps_instructions",
        "plugins_instructions",
        "permissions_instructions",
        "collaboration_mode",
        "multi_agent_mode",
        "system-reminder"
    ]

    /// Some providers persist their bootstrap prompt as the first apparent
    /// message. It is tool metadata, not a request written by the person.
    private static let hiddenBootstrapPrefixes = [
        "you are zcode, an interactive coding agent"
    ]

    /// Removes one or more leading tool-injected envelopes. A truncated
    /// envelope intentionally produces nil instead of leaking a partial config
    /// block into the UI.
    public static func cleanedUserText(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if startsWithHiddenBootstrap(value) { return nil }

        while let tag = leadingTag(in: value), hiddenEnvelopeTags.contains(tag) {
            let closing = "</\(tag)>"
            guard let closeRange = value.range(of: closing, options: .caseInsensitive) else {
                return nil
            }
            value = String(value[closeRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !value.isEmpty, !startsWithHiddenBootstrap(value) else { return nil }
        return value
    }

    /// A compact, single-line preview suitable for cards and search indexes.
    public static func preview(from raw: String, limit: Int = 200) -> String? {
        guard let cleaned = cleanedUserText(raw) else { return nil }
        let compact = collapseWhitespace(cleaned)
        guard !compact.isEmpty else { return nil }
        return clipped(compact, limit: limit)
    }

    /// Derives a stable title when a tool did not provide one.
    public static func title(from raw: String, limit: Int = 64) -> String? {
        guard let cleaned = cleanedUserText(raw) else { return nil }
        let firstLine = cleaned
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard var title = firstLine?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return nil }

        // Markdown headings and list markers are visual syntax, not useful title text.
        title = title.replacingOccurrences(
            of: #"^(?:#{1,6}|[-*+]>?)\s+"#,
            with: "",
            options: .regularExpression
        )
        title = collapseWhitespace(title)
        guard !title.isEmpty else { return nil }
        return clipped(title, limit: limit)
    }

    /// Existing indexes created by older builds need one reparse when their
    /// preview starts with an injected envelope. Clean rows remain incremental.
    public static func needsReindex(title: String?, preview: String) -> Bool {
        if startsWithHiddenEnvelope(preview) || startsWithHiddenBootstrap(preview) { return true }
        if let title,
           startsWithHiddenEnvelope(title) || startsWithHiddenBootstrap(title) {
            return true
        }
        return false
    }

    public static func displayTitle(title: String?, preview: String) -> String? {
        if let title,
           let cleaned = cleanedUserText(title),
           !cleaned.isEmpty,
           cleaned != "无标题" {
            return clipped(collapseWhitespace(cleaned), limit: 80)
        }
        return self.title(from: preview)
    }

    public static func displayPreview(_ preview: String) -> String? {
        self.preview(from: preview, limit: 240)
    }

    /// Whether the index contains enough evidence to offer actions that read
    /// the conversation body. A negative count means a bounded metadata scan
    /// could not compute an exact total; it is not, by itself, proof that a
    /// readable conversation exists. In that case a clean title or preview is
    /// required before the UI offers "view" or "summarize" actions.
    public static func hasReadableConversation(
        messageCount: Int,
        title: String?,
        preview: String
    ) -> Bool {
        if messageCount == 0 { return false }
        if messageCount > 0 { return true }
        return displayTitle(title: title, preview: preview) != nil
            || displayPreview(preview) != nil
    }

    private static func startsWithHiddenEnvelope(_ raw: String) -> Bool {
        guard let tag = leadingTag(in: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return false
        }
        return hiddenEnvelopeTags.contains(tag)
    }

    private static func startsWithHiddenBootstrap(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first?.lowercased() == "y" else { return false }
        let normalized = collapseWhitespace(trimmed).lowercased()
        return hiddenBootstrapPrefixes.contains { normalized.hasPrefix($0) }
    }

    private static func leadingTag(in value: String) -> String? {
        guard value.first == "<", let end = value.firstIndex(of: ">") else { return nil }
        let start = value.index(after: value.startIndex)
        let body = value[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, body.first != "/", body.first != "!", body.first != "?" else {
            return nil
        }
        guard let token = body.split(whereSeparator: \Character.isWhitespace).first else { return nil }
        return token.lowercased()
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
    }

    private static func clipped(_ value: String, limit: Int) -> String {
        guard limit > 0, value.count > limit else { return value }
        return String(value.prefix(max(1, limit - 1))) + "…"
    }
}
