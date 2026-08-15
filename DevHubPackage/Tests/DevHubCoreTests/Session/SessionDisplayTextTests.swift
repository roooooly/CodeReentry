import Testing
@testable import DevHubCore

@Suite("SessionDisplayText")
struct SessionDisplayTextTests {
    @Test("工具注入信封不会成为标题或摘要")
    func stripsInjectedEnvelopes() {
        let raw = """
        <recommended_plugins>
        plugin list
        </recommended_plugins>
        <environment_context>
        <cwd>/tmp/demo</cwd>
        </environment_context>

        优化这个应用的内存与界面
        第二行细节
        """

        #expect(SessionDisplayText.preview(from: raw) == "优化这个应用的内存与界面 第二行细节")
        #expect(SessionDisplayText.title(from: raw) == "优化这个应用的内存与界面")
    }

    @Test("只有信封或被截断的信封不显示")
    func envelopeOnlyIsHidden() {
        #expect(SessionDisplayText.cleanedUserText("<environment_context>x</environment_context>") == nil)
        #expect(SessionDisplayText.cleanedUserText("<recommended_plugins>truncated") == nil)
        #expect(SessionDisplayText.cleanedUserText("<system-reminder>tool context</system-reminder>") == nil)
        #expect(SessionDisplayText.needsReindex(title: nil, preview: "<environment_context>old") == true)
    }

    @Test("工具启动提示不会成为标题且旧索引会重建")
    func bootstrapPromptIsHidden() {
        let raw = "You are ZCode, an interactive coding agent for local projects."
        #expect(SessionDisplayText.cleanedUserText(raw) == nil)
        #expect(SessionDisplayText.displayTitle(title: raw, preview: raw) == nil)
        #expect(SessionDisplayText.needsReindex(title: raw, preview: raw) == true)
    }

    @Test("普通 XML 与用户文本保持可见")
    func preservesOrdinaryText() {
        #expect(SessionDisplayText.cleanedUserText("<div>真实的前端问题</div>") == "<div>真实的前端问题</div>")
        #expect(SessionDisplayText.displayTitle(title: nil, preview: "请修复登录流程") == "请修复登录流程")
    }

    @Test("未知消息数只有在存在可显示元数据时才提供对话操作")
    func readableConversationRequiresEvidenceForUnknownCount() {
        #expect(SessionDisplayText.hasReadableConversation(
            messageCount: 3, title: nil, preview: ""
        ))
        #expect(!SessionDisplayText.hasReadableConversation(
            messageCount: 0, title: "旧标题", preview: "旧摘要"
        ))
        #expect(SessionDisplayText.hasReadableConversation(
            messageCount: -1, title: nil, preview: "真实用户请求"
        ))
        #expect(!SessionDisplayText.hasReadableConversation(
            messageCount: -1, title: nil, preview: ""
        ))
        #expect(!SessionDisplayText.hasReadableConversation(
            messageCount: -1,
            title: nil,
            preview: "<environment_context>truncated"
        ))
    }
}
