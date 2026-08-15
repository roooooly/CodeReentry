import Foundation

/// 子序列模糊匹配 + 连续奖励 + 词边界奖励（§7.2 命令面板）。
public enum FuzzyMatcher {
    public struct Ranked<T> { public let item: T; public let score: Double }

    /// 返回匹配分数；nil 表示不匹配。空 query 返回 0（视为全匹配）。
    public static func score(query: String, target: String) -> Double? {
        if query.isEmpty { return 0 }
        let q = query.lowercased()
        let t = target.lowercased()
        var qi = q.startIndex
        var score: Double = 0
        var streak = 0
        var firstMatch = true
        for ti in t.indices {
            guard qi < q.endIndex else { break }
            if t[ti] == q[qi] {
                streak += 1
                score += 1.0 + Double(streak) * 0.2  // 连续奖励
                if firstMatch { firstMatch = false; score += 0.5 }
                // 词首（前一字符非字母或为空格）加分
                if ti == t.startIndex {
                    score += 0.8
                } else {
                    let prev = t.index(before: ti)
                    if !t[prev].isLetter || t[prev].isWhitespace { score += 0.8 }
                }
                qi = q.index(after: qi)
            } else {
                streak = 0
            }
        }
        return qi == q.endIndex ? score : nil
    }

    public static func rank<T>(query: String, in items: [T], key: (T) -> String) -> [Ranked<T>] {
        items.compactMap { item in
            guard let s = score(query: query, target: key(item)) else { return nil }
            return Ranked(item: item, score: s)
        }
        .sorted { $0.score > $1.score }
    }

    /// 便利重载：String 数组
    public static func rank(query: String, in items: [String]) -> [Ranked<String>] {
        rank(query: query, in: items, key: { $0 })
    }
}
