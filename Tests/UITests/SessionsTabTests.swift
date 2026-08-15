import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("SessionsTab ViewModel")
@MainActor
struct SessionsTabTests {

    @Test("会话按工具分组")
    func groupByTool() throws {
        let env = try SessionsTabTests.makeSessionsEnv(sessions: [
            SessionsTabTests.makeSession(tool: "claude-code", title: "修 bug", preview: "p", age: 60),
            SessionsTabTests.makeSession(tool: "codex", title: "加 feature", preview: "p", age: 30),
            SessionsTabTests.makeSession(tool: "claude-code", title: "重构", preview: "p", age: 600),
        ])
        let vm = SessionsTabViewModel()
        vm.load(project: env.project, from: env.ctx)

        let groups = vm.toolGroups
        #expect(groups.contains(where: { $0.tool == "claude-code" && $0.sessions.count == 2 }))
        #expect(groups.contains(where: { $0.tool == "codex" && $0.sessions.count == 1 }))
    }

    @Test("组内按 startedAt 倒序")
    func groupOrderedByRecency() throws {
        let env = try SessionsTabTests.makeSessionsEnv(sessions: [
            SessionsTabTests.makeSession(tool: "codex", title: "旧", preview: "p", age: 600),
            SessionsTabTests.makeSession(tool: "codex", title: "新", preview: "p", age: 30),
        ])
        let vm = SessionsTabViewModel()
        vm.load(project: env.project, from: env.ctx)
        let codexGroup = vm.toolGroups.first { $0.tool == "codex" }
        #expect(codexGroup?.sessions.first?.title == "新")
    }

    @Test("P0 搜索：title/preview 内存过滤")
    func inMemorySearch() throws {
        let env = try SessionsTabTests.makeSessionsEnv(sessions: [
            SessionsTabTests.makeSession(tool: "claude-code", title: "修复登录 bug", preview: "user msg", age: 60),
            SessionsTabTests.makeSession(tool: "codex", title: "加支付", preview: "支付集成需求", age: 30),
        ])
        let vm = SessionsTabViewModel()
        vm.load(project: env.project, from: env.ctx)

        vm.searchText = "登录"
        #expect(vm.filteredSessions.count == 1)
        #expect(vm.filteredSessions.first?.title == "修复登录 bug")

        vm.searchText = "支付"
        #expect(vm.filteredSessions.count == 1)

        vm.searchText = ""
        #expect(vm.filteredSessions.count == 2)
    }

    @Test("P0 搜索也覆盖工具名与原始会话 ID")
    func searchToolAndSessionId() throws {
        let env = try SessionsTabTests.makeSessionsEnv(sessions: [
            SessionsTabTests.makeSession(tool: "claude-code", title: "普通标题", preview: "普通摘要", age: 60),
            SessionsTabTests.makeSession(tool: "codex", title: "另一个标题", preview: "另一个摘要", age: 30),
        ])
        let vm = SessionsTabViewModel()
        vm.load(project: env.project, from: env.ctx)

        vm.searchText = "claude"
        #expect(vm.filteredSessions.map(\.tool) == ["claude-code"])

        let targetId = env.sessions[1].toolSessionId
        vm.searchText = String(targetId.prefix(8))
        #expect(vm.filteredSessions.map(\.toolSessionId) == [targetId])
    }

    @Test("按工具过滤")
    func toolFilter() throws {
        let env = try SessionsTabTests.makeSessionsEnv(sessions: [
            SessionsTabTests.makeSession(tool: "claude-code", title: "a", preview: "p", age: 10),
            SessionsTabTests.makeSession(tool: "codex", title: "b", preview: "p", age: 5),
        ])
        let vm = SessionsTabViewModel()
        vm.load(project: env.project, from: env.ctx)

        vm.toolFilter = "codex"
        #expect(vm.filteredSessions.count == 1)
        #expect(vm.filteredSessions.first?.tool == "codex")
    }

    @Test("availableTools 列出当前项目的去重工具")
    func availableTools() throws {
        let env = try SessionsTabTests.makeSessionsEnv(sessions: [
            SessionsTabTests.makeSession(tool: "codex", title: "a", preview: "p", age: 1),
            SessionsTabTests.makeSession(tool: "codex", title: "b", preview: "p", age: 2),
            SessionsTabTests.makeSession(tool: "claude-code", title: "c", preview: "p", age: 3),
        ])
        let vm = SessionsTabViewModel()
        vm.load(project: env.project, from: env.ctx)
        #expect(vm.availableTools == ["claude-code", "codex"])
    }

    @Test("无会话 → isEmpty 为 true")
    func emptyState() throws {
        let env = try SessionsTabTests.makeSessionsEnv(sessions: [])
        let vm = SessionsTabViewModel()
        vm.load(project: env.project, from: env.ctx)
        #expect(vm.isEmpty == true)
    }

    @Test("生成总结 → 委托注入的 summaryProvider（触发型 handler）")
    func generateSummaryDelegates() async throws {
        let env = try SessionsTabTests.makeSessionsEnv(sessions: [
            SessionsTabTests.makeSession(tool: "codex", title: "x", preview: "p", age: 5),
        ])
        let vm = SessionsTabViewModel()
        vm.load(project: env.project, from: env.ctx)

        var summarized: String?
        vm.generateSummaryHandler = { session in
            summarized = session.toolSessionId
        }
        try await vm.generateSummary(for: env.sessions[0])
        #expect(summarized == env.sessions[0].toolSessionId)
    }

    @Test("在原工具继续 → 委托注入的 resumeHandler")
    func resumeDelegates() async throws {
        let env = try SessionsTabTests.makeSessionsEnv(sessions: [
            SessionsTabTests.makeSession(tool: "codex", title: "x", preview: "p", age: 5),
        ])
        let vm = SessionsTabViewModel()
        vm.load(project: env.project, from: env.ctx)

        var resumed: String?
        vm.resumeHandler = { session in resumed = session.toolSessionId }
        try await vm.resumeInOriginalTool(env.sessions[0])
        #expect(resumed == env.sessions[0].toolSessionId)
    }

    @Test("子目录会话的总结仍写入已注册项目根目录")
    func summaryDestinationUsesRegisteredProjectRoot() {
        let destination = SessionMemoryDestination.projectRoot(
            registeredProjectPath: "/repo",
            sessionCwd: "/repo/packages/client"
        )

        #expect(destination == "/repo")
    }

    // MARK: - fixtures

    struct SessionsEnv {
        let container: ModelContainer
        let ctx: ModelContext
        let project: Project
        let sessions: [SessionIndex]
    }

    static func makeSessionsEnv(sessions: [(tool: String, title: String, preview: String, age: Int)]) throws -> SessionsEnv {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let project = ProjectFixtures.makeProject(name: "ExampleApp", path: "/tmp/ExampleApp", isPinned: true, group: nil, tags: [])
        ctx.insert(project)

        let now = Date()
        var models: [SessionIndex] = []
        for s in sessions {
            let m = SessionIndex(
                tool: s.tool,
                toolSessionId: UUID().uuidString,
                sourcePath: "/tmp/test.jsonl",
                projectCwd: "/tmp/ExampleApp",
                startedAt: now.addingTimeInterval(TimeInterval(-s.age)),
                updatedAt: now.addingTimeInterval(TimeInterval(-s.age)),
                messageCount: 3,
                title: s.title,
                preview: s.preview,
                project: project
            )
            ctx.insert(m)
            models.append(m)
        }
        try ctx.save()
        return SessionsEnv(container: container, ctx: ctx, project: project, sessions: models)
    }

    static func makeSession(tool: String, title: String, preview: String, age: Int)
        -> (tool: String, title: String, preview: String, age: Int) {
        (tool, title, preview, age)
    }
}
