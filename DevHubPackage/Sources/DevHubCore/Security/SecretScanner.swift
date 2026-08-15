import Foundation

public enum SecretKind: String, Sendable, Equatable, CaseIterable {
    case awsKey
    case gcpKey
    case assignment
    case pemPrivateKey
    case longRandom
}

public struct ScanResult: Sendable, Equatable {
    public let hits: Set<SecretKind>
    public init(hits: Set<SecretKind>) { self.hits = hits }

    /// §5.2 命中任何秘密就阻止位置参数注入
    public var blocksPositionalInjection: Bool { !hits.isEmpty }
}

public enum SecretScanner {

    public static func scan(_ text: String) -> Set<SecretKind> {
        scanDetail(text).hits
    }

    public static func hasSecrets(in text: String) -> Bool {
        !scan(text).isEmpty
    }

    public static func scanDetail(_ text: String) -> ScanResult {
        var hits: Set<SecretKind> = []
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern.regex, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    hits.insert(pattern.kind)
                }
            }
        }
        return ScanResult(hits: hits)
    }

    private static let patterns: [(kind: SecretKind, regex: String)] = [
        (.awsKey, #"AKIA[0-9A-Z]{16}"#),
        (.gcpKey, #"AIza[0-9A-Za-z_\-]{35}"#),
        (.pemPrivateKey, #"-----BEGIN[ A-Z]*PRIVATE KEY-----"#),
        (.assignment, #"(?i)(api[_-]?key|token|secret|password)\s*[:=]\s*['\"]?[^\s'\"$]{1,}"#),
        (.longRandom, #"[A-Za-z0-9+/=]{32,}"#),
        (.longRandom, #"\b[0-9a-fA-F]{32,}\b"#),
    ]
}
