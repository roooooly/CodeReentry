import Foundation

/// Claude Code 与 Codex 的 JSONL 都允许 message content 为字符串或结构化数组。
/// 这里抽取人类可读文本块；thinking 等内部载荷默认忽略，tool_use 默认忽略
/// （摘要路径），但正文查看器可传 `includeToolUse: true` 把工具调用渲染成可读文本。
enum SessionContentExtractor {

    /// 抽取可读文本。
    /// - Parameter includeToolUse: 为 true 时把 tool_use/function_call 块渲染成
    ///   「🔧 {name}\n{input}」拼进结果；为 false（默认）时跳过，保持摘要路径行为不变。
    static func text(from value: Any?, includeToolUse: Bool = false) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            return normalized(string)
        }
        if let array = value as? [Any] {
            let pieces = array.compactMap { textBlock(from: $0, includeToolUse: includeToolUse) }
            return normalized(pieces.joined(separator: "\n"))
        }
        if let object = value as? [String: Any] {
            return textBlock(from: object, includeToolUse: includeToolUse)
        }
        return nil
    }

    private static func textBlock(from value: Any, includeToolUse: Bool) -> String? {
        if let string = value as? String { return normalized(string) }
        guard let object = value as? [String: Any] else { return nil }

        let type = (object["type"] as? String)?.lowercased()
        switch type {
        case "thinking", "redacted_thinking", "computer_initialize_state":
            return nil
        case "tool_use", "function_call":
            // 正文查看器需要工具调用；摘要路径跳过。
            return includeToolUse ? formatToolUseBlock(from: object) : nil
        default:
            break
        }

        if let text = object["text"] as? String {
            return normalized(text)
        }
        // Claude tool_result 的 content 可能再嵌一层文本数组；保留真正的文字反馈。
        if let nested = object["content"] {
            return text(from: nested, includeToolUse: includeToolUse)
        }
        return nil
    }

    /// 把 tool_use / function_call 块格式化成可读文本「🔧 {name}\n{input}」。
    private static func formatToolUseBlock(from object: [String: Any]) -> String? {
        let name = (object["name"] as? String) ?? String(localized: "工具调用")
        let input: String
        if let arguments = object["arguments"] as? String {
            // Codex function_call 的 arguments 通常是 JSON 字符串
            input = prettyJson(arguments) ?? arguments
        } else if let inp = object["input"] {
            if let data = try? JSONSerialization.data(withJSONObject: inp, options: [.prettyPrinted, .sortedKeys]),
               let s = String(data: data, encoding: .utf8) {
                input = s
            } else {
                input = "\(inp)"
            }
        } else {
            input = ""
        }
        return normalized("🔧 \(name)\n\(input)")
    }

    /// 抽取 content 里所有 tool_use/function_call 块的 (name, input)。
    /// 供 reader 为正文视图构造 `SessionMessage(role: .tool, ...)`。
    static func toolUseBlocks(from value: Any?) -> [(name: String, input: String)] {
        guard let array = value as? [Any] else { return [] }
        var blocks: [(name: String, input: String)] = []
        for item in array {
            guard let object = item as? [String: Any] else { continue }
            let type = (object["type"] as? String)?.lowercased()
            guard type == "tool_use" || type == "function_call" else { continue }
            let name = (object["name"] as? String) ?? String(localized: "工具调用")
            let input: String
            if let arguments = object["arguments"] as? String {
                input = prettyJson(arguments) ?? arguments
            } else if let inp = object["input"] {
                if let data = try? JSONSerialization.data(withJSONObject: inp, options: [.prettyPrinted, .sortedKeys]),
                   let s = String(data: data, encoding: .utf8) {
                    input = s
                } else {
                    input = "\(inp)"
                }
            } else {
                input = ""
            }
            blocks.append((name: name, input: input))
        }
        return blocks
    }

    /// 尝试把 JSON 字符串美化；失败原样返回。
    private static func prettyJson(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let s = String(data: pretty, encoding: .utf8) else { return nil }
        return s
    }

    private static func normalized(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
