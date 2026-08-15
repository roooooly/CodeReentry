import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("ProjectsOverviewViewModel")
@MainActor
struct ProjectsOverviewViewModelTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    @Test("load projects and project card data mapping")
    func loadProjects() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let p1 = ProjectFixtures.makeProject(name: "ExampleApp", path: "/tmp/ExampleApp",
                                             isPinned: true, tags: ["ai"])
        p1.statusEnum = .completed
        p1.version = "1.0.0"
        ctx.insert(p1)

        let p2 = ProjectFixtures.makeProject(name: "tools", path: "/tmp/tools")
        p2.statusEnum = .active
        ctx.insert(p2)
        try ctx.save()

        let vm = ProjectsOverviewViewModel()
        vm.load(from: container)

        #expect(vm.cards.count == 2)
        let exampleApp = vm.cards.first { $0.name == "ExampleApp" }!
        #expect(exampleApp.status == .completed)
        #expect(exampleApp.version == "1.0.0")
        #expect(exampleApp.toolCount == 0)
        #expect(exampleApp.sessionCount == 0)

        // 状态分布
        #expect(vm.statusDistribution[.completed] == 1)
        #expect(vm.statusDistribution[.active] == 1)
    }

    @Test("status filter narrows visible cards")
    func statusFilter() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let p1 = ProjectFixtures.makeProject(name: "A", path: "/tmp/A")
        p1.statusEnum = .active
        let p2 = ProjectFixtures.makeProject(name: "B", path: "/tmp/B")
        p2.statusEnum = .paused
        ctx.insert(p1); ctx.insert(p2)
        try ctx.save()

        let vm = ProjectsOverviewViewModel()
        vm.load(from: container)
        #expect(vm.visibleCards.count == 2)

        vm.statusFilter = .paused
        #expect(vm.visibleCards.count == 1)
        #expect(vm.visibleCards.first?.status == .paused)

        vm.statusFilter = nil
        #expect(vm.visibleCards.count == 2)
    }

    @Test("fuzzy search ranks and filters by name")
    func fuzzySearch() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        for n in ["alpha-core", "beta-tools", "gamma-ai"] {
            ctx.insert(ProjectFixtures.makeProject(name: n, path: "/tmp/\(n)"))
        }
        try ctx.save()

        let vm = ProjectsOverviewViewModel()
        vm.load(from: container)

        vm.searchText = "too"
        let results = vm.visibleCards
        #expect(results.count == 1)
        #expect(results.first?.name == "beta-tools")

        vm.searchText = "a"
        // 所有三个名字都含 'a'
        #expect(vm.visibleCards.count == 3)

        vm.searchText = "zzz"
        #expect(vm.visibleCards.isEmpty)
    }

    @Test("subscription monthly cost aggregated by currency")
    func monthlyCostAggregation() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let project = ProjectFixtures.makeProject(name: "ExampleApp", path: "/tmp/ExampleApp")
        ctx.insert(project)

        let usd = Subscription(name: "ChatGPT", provider: "OpenAI", amount: 20,
                               currency: "USD", cycle: .monthly,
                               nextRenewal: Date(timeIntervalSince1970: 1_900_000_000))
        usd.project = project
        ctx.insert(usd)
        let cny = Subscription(name: "GLM", provider: "Zhipu", amount: 120,
                               currency: "CNY", cycle: .yearly,
                               nextRenewal: Date(timeIntervalSince1970: 1_910_000_000))
        cny.project = project
        ctx.insert(cny)
        try ctx.save()

        let vm = ProjectsOverviewViewModel()
        vm.load(from: container)

        // 120 CNY yearly → 10 CNY/mo；20 USD monthly → 20 USD/mo
        let card = vm.cards.first!
        #expect(card.monthlyCostByCurrency["USD"] == 20)
        #expect(card.monthlyCostByCurrency["CNY"] == 10)
    }

    @Test("cardData static mapping reflects relationships")
    func cardDataMapping() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let project = ProjectFixtures.makeProject(name: "tools", path: "/tmp/tools")
        project.color = "#FF8800"
        project.icon = "hammer.fill"
        ctx.insert(project)

        let tool = Tool(name: "claude", kind: .cli, launchCommand: "claude",
                        workingDirMode: .projectRoot, injectionMode: .cliFlag, sortOrder: 0)
        tool.projects = [project]
        ctx.insert(tool)

        let session = SessionIndex(tool: "claude", toolSessionId: "s1",
                                   sourcePath: "/tmp/s1.jsonl",
                                   projectCwd: "/tmp/tools", startedAt: Date(),
                                   updatedAt: Date(), messageCount: 5,
                                   title: "Demo", preview: "hello")
        session.project = project
        ctx.insert(session)
        let emptyBoundedSession = SessionIndex(
            tool: "zcode", toolSessionId: "z-empty",
            sourcePath: "/tmp/z-empty.jsonl", projectCwd: "/tmp/tools",
            startedAt: Date().addingTimeInterval(10),
            updatedAt: Date().addingTimeInterval(10), messageCount: -1,
            title: nil, preview: ""
        )
        emptyBoundedSession.project = project
        ctx.insert(emptyBoundedSession)
        try ctx.save()

        let data = ProjectsOverviewViewModel.cardData(for: project)
        #expect(data.toolCount == 1)
        #expect(data.sessionCount == 2)
        #expect(data.colorHex == "#FF8800")
        #expect(data.icon == "hammer.fill")
        #expect(data.lastActivityAt != nil)
        #expect(data.latestSession?.tool == "claude")
        #expect(data.latestSession?.sessionId == "s1")
        #expect(data.latestSession?.title == "Demo")
    }
}
