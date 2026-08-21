import Testing
import SwiftUI
import SwiftData
import SnapshotTesting
import DevHubCore
@testable import DevHub

/// 多视图 snapshot gallery——生成各主界面的渲染基线，用于直观查看 UI 效果。
///
/// 用 `.record(.missing)`：基线缺失时写入 PNG，已存在则比对。
/// 运行 `swift test` 后在 `__Snapshots__/GallerySnapshotTests/` 下查看每张图。
@Suite("UI Gallery Snapshots")
@MainActor
struct GallerySnapshotTests {

    private func makeDeps(container: ModelContainer) -> AppDependencies {
        let deps = AppDependencies(modelContainer: container)
        let tc = TerminalController()
        // stub 掉 AppleScript 执行，避免测试里真的唤起 Terminal.app
        tc.executor = { _ in nil }
        deps.overrideServices(terminalController: tc)
        return deps
    }

    private func makeContainer(withProjects: Bool = false) throws -> ModelContainer {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        if withProjects {
            let ctx = container.mainContext
            for p in ProjectFixtures.makeProjects() { ctx.insert(p) }
            try ctx.save()
        }
        return container
    }

    @Test("Onboarding 欢迎页")
    func onboardingWelcome() throws {
        let container = try makeContainer()
        let deps = makeDeps(container: container)
        let view = OnboardingView(dependencies: deps, onComplete: {})
            .environment(deps)
            .modelContainer(container)
        let vc = NSHostingController(rootView: view)
        assertSnapshot(of: vc, as: .image(size: CGSize(width: 720, height: 540)),
                       record: .missing, timeout: 30)
    }

    @Test("Onboarding 首次会话扫描页")
    func onboardingSessionScan() throws {
        let container = try makeContainer()
        let deps = makeDeps(container: container)
        let flow = OnboardingFlow()
        flow.goToIntro()
        let view = OnboardingView(dependencies: deps, onComplete: {}, flow: flow)
            .environment(deps)
            .modelContainer(container)
        let vc = NSHostingController(rootView: view)
        assertSnapshot(of: vc, as: .image(size: CGSize(width: 720, height: 540)),
                       record: .missing, timeout: 30)
    }

    @Test("Sidebar 项目列表")
    func sidebarWithProjects() throws {
        let container = try makeContainer(withProjects: true)
        let deps = makeDeps(container: container)
        let view = SidebarView()
            .environment(deps)
            .modelContainer(container)
            .frame(width: 240, height: 600)
            .background(Color(nsColor: .windowBackgroundColor))
        let vc = NSHostingController(rootView: view)
        assertSnapshot(of: vc, as: .image(size: CGSize(width: 240, height: 600)),
                       record: .missing, timeout: 30)
    }

    @Test("ProjectDetail Subscriptions tab")
    func subscriptionsTab() async throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let project = ProjectFixtures.makeProject(name: "ExampleApp", path: "/tmp/ExampleApp",
                                                  isPinned: true, group: nil, tags: ["ai"])
        ctx.insert(project)
        try ctx.save()
        let deps = makeDeps(container: container)
        let store = SubscriptionStore(modelContainer: container)
        let chatGPT = Subscription(
            name: "ChatGPT Pro", provider: "OpenAI", amount: 20, currency: "USD",
            cycle: .monthly, nextRenewal: Date(timeIntervalSince1970: 1_900_000_000)
        )
        chatGPT.project = project
        ctx.insert(chatGPT)
        let glm = Subscription(
            name: "GLM API", provider: "Zhipu", amount: 144, currency: "CNY",
            cycle: .yearly, nextRenewal: Date(timeIntervalSince1970: 1_910_000_000)
        )
        glm.project = project
        ctx.insert(glm)
        try ctx.save()

        let viewModel = SubscriptionsTabViewModel(projectId: project.id, store: store)
        await viewModel.load()
        let view = SubscriptionsTab(project: project, store: store, viewModel: viewModel)
            .environment(deps)
            .modelContainer(container)
            .frame(width: 800, height: 600)
        let vc = NSHostingController(rootView: view)
        assertSnapshot(of: vc, as: .image(size: CGSize(width: 800, height: 600)),
                       record: .missing, timeout: 30)
    }

    @Test("Memory tab 编辑器")
    func memoryTab() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let project = ProjectFixtures.makeProject(name: "ExampleApp", path: "/tmp/ExampleApp",
                                                  isPinned: true, group: nil, tags: [])
        ctx.insert(project)
        try ctx.save()
        let deps = makeDeps(container: container)
        let view = MemoryTab(project: project)
            .environment(deps)
            .modelContainer(container)
            .frame(width: 700, height: 500)
        let vc = NSHostingController(rootView: view)
        assertSnapshot(of: vc, as: .image(size: CGSize(width: 700, height: 500)),
                       record: .missing, timeout: 30)
    }

    @Test("命令面板 ⌘K")
    func commandPalette() throws {
        let container = try makeContainer(withProjects: true)
        let deps = makeDeps(container: container)
        let items: [CommandItem] = [
            .openProject(name: "ExampleApp", stableId: "s1"),
            .openProject(name: "developer-tools", stableId: "s2"),
            .switchTab(name: "工具", tab: .tools),
            .switchTab(name: "订阅", tab: .subscriptions),
        ]
        let vm = CommandPaletteViewModel(allItems: items)
        vm.query = "e"
        vm.update()
        let view = CommandPaletteView(viewModel: vm, onCancel: {})
            .environment(deps)
            .frame(width: 500, height: 360)
        let vc = NSHostingController(rootView: view)
        assertSnapshot(of: vc, as: .image(size: CGSize(width: 500, height: 360)),
                       record: .missing, timeout: 30)
    }

    @Test("项目卡片 ProjectCardView")
    func projectCard() throws {
        let data = ProjectCardData(
            id: UUID(), stableId: "s1", name: "ExampleApp",
            icon: "hammer.fill", colorHex: "#3B82F6",
            status: .active, version: "1.2.0",
            pathAvailable: true,
            toolCount: 3, sessionCount: 12,
            monthlyCostByCurrency: ["USD": 20],
            lastActivityAt: Date().addingTimeInterval(-3600)
        )
        let view = ProjectCardView(data: data)
            .frame(width: 300)
            .background(Color(nsColor: .windowBackgroundColor))
        let vc = NSHostingController(rootView: view)
        assertSnapshot(of: vc, as: .image(size: CGSize(width: 320, height: 220)),
                       record: .missing, timeout: 30)
    }

    @Test("项目总览卡片网格")
    func projectsOverview() throws {
        let container = try makeContainer(withProjects: true)
        let ctx = container.mainContext
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-projects-overview-fixtures", isDirectory: true)
        try? FileManager.default.removeItem(at: fixtureRoot)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        // Marketing-facing snapshot fixtures must look usable while remaining fully
        // synthetic. Give every project a temporary live path instead of rendering a
        // wall of intentional "missing path" warnings from the shared unit fixtures.
        let projects = try ctx.fetch(FetchDescriptor<Project>())
        for project in projects {
            let path = fixtureRoot.appendingPathComponent(project.name, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            project.path = path.path
            switch project.name {
            case "archived-demo": project.statusEnum = .archived
            case "sample-workspace": project.statusEnum = .completed
            default: project.statusEnum = .active
            }
        }

        if let exampleApp = projects.first(where: { $0.name == "ExampleApp" }) {
            exampleApp.statusEnum = .active
            exampleApp.version = "0.9.0"
            exampleApp.color = "#3B82F6"
            let session = SessionIndex(
                tool: "claude-code",
                toolSessionId: "synthetic-session-1",
                sourcePath: fixtureRoot.appendingPathComponent("session.jsonl").path,
                projectCwd: exampleApp.path,
                startedAt: Date(timeIntervalSince1970: 1_900_000_000),
                updatedAt: Date(timeIntervalSince1970: 1_900_003_600),
                messageCount: 12,
                title: "Prepare the next release",
                preview: "Review the release checklist",
                project: exampleApp
            )
            ctx.insert(session)
        }
        try ctx.save()
        let deps = makeDeps(container: container)
        let view = ProjectsOverviewView()
            .environment(deps)
            .modelContainer(container)
            .frame(width: 1000, height: 680)
            .background(Color(nsColor: .windowBackgroundColor))
        let vc = NSHostingController(rootView: view)
        assertSnapshot(of: vc, as: .image(size: CGSize(width: 1000, height: 680)),
                       record: .missing, timeout: 30)
    }

    @Test("会话正文查看器")
    func sessionDetail() {
        let session = SessionIndex(
            tool: "claude-code", toolSessionId: "s1",
            sourcePath: "/tmp/s.jsonl", projectCwd: "/tmp/P",
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_750_010_000),
            messageCount: 2, title: "修复登录 bug", preview: "登录页面报错"
        )
        let stub = SnapshotStubReader(messages: [
            SessionMessage(role: .user, content: "帮我修复登录页面的报错", timestamp: Date(timeIntervalSince1970: 1_750_000_000)),
            SessionMessage(role: .assistant, content: "好的，我先看一下 `LoginView.swift` 的实现。", timestamp: Date(timeIntervalSince1970: 1_750_000_500))
        ])
        let vm = SessionDetailViewModel(session: session, reader: stub)
        let view = SessionDetailView(viewModel: vm)
            .background(Color(nsColor: .windowBackgroundColor))
        let vc = NSHostingController(rootView: view)
        assertSnapshot(of: vc, as: .image(size: CGSize(width: 760, height: 620)),
                       record: .missing, timeout: 30)
    }

    // 注：UsageOverviewView 含"最近 14 天"等依赖当天日期的图表，快照会随日期漂移，
    // 故不纳入 snapshot gallery；其数据正确性由 Core 层 UsageAggregator/Reader 单测覆盖。
}

private struct SnapshotStubReader: SessionReader {
    let toolId = "claude-code"
    let messages: [SessionMessage]
    func discover() async throws -> [DiscoveredSession] { [] }
    func load(_ id: String) async throws -> SessionDetail {
        SessionDetail(tool: "claude-code", toolSessionId: id, cwd: "/tmp/P",
                      startedAt: Date(timeIntervalSince1970: 1_750_000_000), messages: messages)
    }
}
