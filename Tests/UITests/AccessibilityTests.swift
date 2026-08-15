import Testing
import Foundation
@testable import DevHub

@Suite("i18n + a11y 基础审查")
struct AccessibilityTests {

    @Test("DetailTab 标题全部非空")
    func detailTabTitlesLocalized() {
        for tab in DetailTab.allCases {
            let s = tab.title
            #expect(s.isEmpty == false)
        }
    }

    @Test("SettingsTab 标题全部非空")
    func settingsTabTitlesLocalized() {
        for tab in SettingsTab.allCases {
            let s = tab.title
            #expect(s.isEmpty == false)
        }
    }

    @Test("应用语言提供系统、简体中文与英文")
    func supportedAppLanguages() {
        #expect(AppLanguage.allCases == [.system, .simplifiedChinese, .english])
        #expect(AppLanguage.resolved("unsupported") == .simplifiedChinese)
    }

    @Test("关键界面文案同时提供简体中文与英文资源")
    func keyStringsExistInBothLanguages() throws {
        let englishURL = try #require(Bundle.main.url(forResource: "en", withExtension: "lproj"))
        let chineseURL = try #require(Bundle.main.url(forResource: "zh-Hans", withExtension: "lproj"))
        let english = try #require(Bundle(url: englishURL))
        let chinese = try #require(Bundle(url: chineseURL))

        #expect(english.localizedString(forKey: "MCP 工具", value: nil, table: nil) == "MCP Tools")
        #expect(chinese.localizedString(forKey: "MCP 工具", value: nil, table: nil) == "MCP 工具")
    }

    @Test("PlaceholderStage rawValue 为 P1/P2（用于 badge 文本）")
    func placeholderStageRawValues() {
        #expect(PlaceholderStage.p1.rawValue == "P1")
        #expect(PlaceholderStage.p2.rawValue == "P2")
    }

    @Test("DetailTab 6 个 tab 全部可访问 title（无空标题）")
    func noEmptyTabTitles() {
        #expect(DetailTab.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(DetailTab.allCases.count == 6)
    }

    @Test("ToolColor 给已知工具返回语义颜色名")
    func toolColorKnown() {
        #expect(ToolColor.color(for: "claude-code") == "orange")
        #expect(ToolColor.color(for: "codex") == "green")
        #expect(ToolColor.color(for: "unknown") == "gray")
    }
}
