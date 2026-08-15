import Testing
import Foundation
@testable import DevHubCore

@Suite("FuzzyMatcher")
struct FuzzyMatcherTests {

    @Test("精确子串高分")
    func exactSubstring() {
        let r = FuzzyMatcher.score(query: "exa", target: "ExampleApp")
        #expect(r != nil)
    }

    @Test("大小写不敏感")
    func caseInsensitive() {
        #expect(FuzzyMatcher.score(query: "exampleapp", target: "EXAMPLEAPP project") != nil)
        #expect(FuzzyMatcher.score(query: "EXA", target: "ExampleApp") != nil)
    }

    @Test("非匹配返回 nil")
    func noMatch() {
        #expect(FuzzyMatcher.score(query: "xyz", target: "ExampleApp") == nil)
    }

    @Test("子序列匹配得分低于精确")
    func subsequenceLowerThanExact() {
        let exact = FuzzyMatcher.score(query: "exa", target: "ExampleApp")!
        let subseq = FuzzyMatcher.score(query: "exa", target: "ExtraordinaryApp")!
        #expect(exact > subseq)
    }

    @Test("词边界匹配加分")
    func wordBoundaryBonus() {
        let boundary = FuzzyMatcher.score(query: "vs", target: "VS Code")!
        let middle = FuzzyMatcher.score(query: "vs", target: "Kovs")!
        #expect(boundary > middle)
    }

    @Test("rank 排序按分降序，不匹配剔除")
    func rankOrdersByScore() {
        let items = ["ExampleApp", "ExtraordinaryApp", "SampleWorkspace"]
        let ranked = FuzzyMatcher.rank(query: "exa", in: items)
        #expect(ranked.first?.item == "ExampleApp")
        #expect(ranked.contains(where: { $0.item == "SampleWorkspace" }) == false)
    }

    @Test("空 query 返回全部，分数为 0")
    func emptyQuery() {
        let ranked = FuzzyMatcher.rank(query: "", in: ["A", "B"])
        #expect(ranked.count == 2)
        #expect(ranked.allSatisfy { $0.score == 0 })
    }

    @Test("rank 用自定义 key")
    func rankWithKey() {
        struct P { let name: String }
        let items = [P(name: "ExampleApp"), P(name: "tools")]
        let ranked = FuzzyMatcher.rank(query: "em", in: items, key: { $0.name })
        #expect(ranked.count == 1)
        #expect(ranked.first?.item.name == "ExampleApp")
    }
}
