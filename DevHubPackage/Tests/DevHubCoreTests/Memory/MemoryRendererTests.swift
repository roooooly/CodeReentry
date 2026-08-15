import Testing
import Foundation
@testable import DevHubCore

@Suite("MemoryRenderer")
struct MemoryRendererTests {

    @Test("renders context only when no summary")
    func contextOnly() {
        let rendered = MemoryRenderer.render(
            context: "# ExampleApp\n项目用 SwiftUI",
            lastSessionSummary: nil,
            gitStatus: nil
        )
        #expect(rendered.contains("# ExampleApp"))
        #expect(rendered.contains("项目用 SwiftUI"))
        #expect(!rendered.contains("## 上次会话摘要"))
        #expect(!rendered.contains("## Git 状态"))
    }

    @Test("renders context + summary")
    func contextAndSummary() {
        let rendered = MemoryRenderer.render(
            context: "# ExampleApp",
            lastSessionSummary: "上次改了登录",
            gitStatus: nil
        )
        #expect(rendered.contains("## 上次会话摘要"))
        #expect(rendered.contains("上次改了登录"))
    }

    @Test("renders context + summary + git status")
    func contextSummaryGit() {
        let rendered = MemoryRenderer.render(
            context: "# ExampleApp",
            lastSessionSummary: "上次改了登录",
            gitStatus: GitStatus(branch: "main", lastCommitSubject: "init", dirtyFileCount: 3)
        )
        #expect(rendered.contains("## Git 状态"))
        #expect(rendered.contains("main"))
        #expect(rendered.contains("init"))
        #expect(rendered.contains("3 个未提交文件"))
    }

    @Test("empty context still renders header structure")
    func emptyContext() {
        let rendered = MemoryRenderer.render(context: "", lastSessionSummary: nil, gitStatus: nil)
        #expect(rendered.contains("# 项目记忆"))
        #expect(!rendered.isEmpty)
    }
}
