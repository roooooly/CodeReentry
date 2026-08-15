import Foundation

public enum ConfiguredCommandError: Error, Equatable, LocalizedError {
    case empty
    case unterminatedQuote
    case danglingEscape

    public var errorDescription: String? {
        switch self {
        case .empty: return String(localized: "启动命令不能为空。")
        case .unterminatedQuote: return String(localized: "启动命令包含未闭合的引号。")
        case .danglingEscape: return String(localized: "启动命令末尾包含不完整的转义符。")
        }
    }
}

/// 把设置中的“可执行文件 + 固定参数”拆成 argv，不经过 shell 展开。
/// 已存在的完整文件路径优先按一个 executable 处理，因此带空格的 `.app`/脚本路径
/// 无需额外加引号；其他输入支持常见的单引号、双引号和反斜杠分词。
public enum ConfiguredCommand {
    public static func parse(
        _ configured: String?,
        fallbackExecutable: String,
        appending additionalArguments: [String] = []
    ) throws -> CommandSpec {
        let raw = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selected = raw.isEmpty ? fallbackExecutable : raw
        guard !selected.isEmpty else { throw ConfiguredCommandError.empty }

        let expandedExact = (selected as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedExact) {
            return CommandSpec(executable: expandedExact, arguments: additionalArguments)
        }

        let tokens = try tokenize(selected)
        guard let first = tokens.first else { throw ConfiguredCommandError.empty }
        let executable = (first as NSString).expandingTildeInPath
        return CommandSpec(
            executable: executable,
            arguments: Array(tokens.dropFirst()) + additionalArguments
        )
    }

    public static func tokenize(_ command: String) throws -> [String] {
        enum Quote: Equatable { case single, double }
        var quote: Quote?
        var escaped = false
        var current = ""
        var tokens: [String] = []
        var tokenStarted = false

        for character in command {
            if escaped {
                current.append(character)
                tokenStarted = true
                escaped = false
                continue
            }
            if character == "\\", quote != .single {
                escaped = true
                tokenStarted = true
                continue
            }
            switch (quote, character) {
            case (.single, "'"):
                quote = nil
            case (.double, "\""):
                quote = nil
            case (nil, "'"):
                quote = .single
                tokenStarted = true
            case (nil, "\""):
                quote = .double
                tokenStarted = true
            case (nil, let value) where value.isWhitespace:
                if tokenStarted {
                    tokens.append(current)
                    current = ""
                    tokenStarted = false
                }
            default:
                current.append(character)
                tokenStarted = true
            }
        }
        if escaped { throw ConfiguredCommandError.danglingEscape }
        if quote != nil { throw ConfiguredCommandError.unterminatedQuote }
        if tokenStarted { tokens.append(current) }
        return tokens
    }
}
