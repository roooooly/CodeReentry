import Foundation

/// 注入准备结果（§5.2）。
public struct InjectionPreparation: Sendable, Equatable {
    public let rendered: String
    public let mode: InjectionMode
    public let scannedSecrets: Set<SecretKind>
    public let truncated: Bool
    public let fellBackFromPositional: Bool

    public init(rendered: String, mode: InjectionMode, scannedSecrets: Set<SecretKind>, truncated: Bool, fellBackFromPositional: Bool) {
        self.rendered = rendered
        self.mode = mode
        self.scannedSecrets = scannedSecrets
        self.truncated = truncated
        self.fellBackFromPositional = fellBackFromPositional
    }
}

/// 注入流程编排（§5.2）：
/// render → scan → if secret and positional, block+fallback → length cap 8KB → pick mode。
public enum InjectionManager {

    /// 上限按 UTF-8 字节计算；`String.count` 是字素数，中文等多字节内容会严重低估 argv 大小。
    public static let maxLength = 8192  // 8 KiB, retained name for source compatibility
    public static let truncationSuffix = "\n\n" + String(localized: "...（已截断，完整内容见 .devhub/memory/context.md）")

    public static func prepare(
        context: String,
        lastSessionSummary: String?,
        gitStatus: GitStatus?,
        preferredMode: InjectionMode,
        allowCliFlagFallback: Bool = true
    ) -> InjectionPreparation {
        // 1. Render
        var rendered = MemoryRenderer.render(
            context: context,
            lastSessionSummary: lastSessionSummary,
            gitStatus: gitStatus
        )

        // 2. Scan
        let scanResult = SecretScanner.scanDetail(rendered)
        let secrets = scanResult.hits

        // 3. Pick mode (with secret-aware fallback)
        var mode = preferredMode
        var fellBack = false
        if !secrets.isEmpty && mode == .positionalArg {
            // positional 命中秘密 → 降级
            if allowCliFlagFallback {
                mode = .cliFlag
                fellBack = true
            } else {
                mode = .clipboard
                fellBack = true
            }
        }

        // 4. Length cap
        var truncated = false
        if rendered.utf8.count > maxLength {
            let prefixBudget = max(0, maxLength - truncationSuffix.utf8.count)
            var used = 0
            var end = rendered.startIndex
            for character in rendered {
                let bytes = String(character).utf8.count
                guard used + bytes <= prefixBudget else { break }
                used += bytes
                end = rendered.index(after: end)
            }
            rendered = String(rendered[..<end]) + truncationSuffix
            truncated = true
        }

        return InjectionPreparation(
            rendered: rendered,
            mode: mode,
            scannedSecrets: secrets,
            truncated: truncated,
            fellBackFromPositional: fellBack
        )
    }
}
