import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("AllSessionsViewModel")
@MainActor
struct AllSessionsViewModelTests {
    @Test("加载全部项目会话并支持未分类筛选")
    func loadsAllAndFiltersUnclassified() throws {
        let env = try makeEnvironment()
        let viewModel = AllSessionsViewModel()
        viewModel.load(from: env.container)

        #expect(viewModel.allSessions.count == 3)
        #expect(viewModel.unclassifiedCount == 1)
        viewModel.scope = .unclassified
        #expect(viewModel.filteredSessions.map(\.toolSessionId) == ["z-unclassified"])
    }

    @Test("全局搜索覆盖 tool、toolSessionId 与项目名")
    func searchCachedMetadata() throws {
        let env = try makeEnvironment()
        let viewModel = AllSessionsViewModel()
        viewModel.load(from: env.container)

        viewModel.searchText = "claude"
        #expect(viewModel.filteredSessions.map(\.toolSessionId) == ["claude-1"])

        viewModel.searchText = "z-unclass"
        #expect(viewModel.filteredSessions.map(\.toolSessionId) == ["z-unclassified"])

        viewModel.searchText = "项目甲"
        #expect(viewModel.filteredSessions.map(\.toolSessionId).sorted() == ["claude-1", "z-classified"])
    }

    @Test("长会话列表分批展示，筛选变化后恢复首批")
    func longListsLoadInPagesAndFiltersResetTheLimit() throws {
        let env = try makeEnvironment()
        for index in 0..<60 {
            env.container.mainContext.insert(SessionIndex(
                tool: "codex", toolSessionId: "paged-\(index)",
                sourcePath: "/tmp/paged-\(index).jsonl", projectCwd: env.project.path,
                startedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(1_000 + index)),
                messageCount: 1, title: "paged \(index)", preview: "preview", project: env.project
            ))
        }
        try env.container.mainContext.save()

        let viewModel = AllSessionsViewModel()
        viewModel.load(from: env.container)
        #expect(viewModel.filteredSessions.count == 63)
        #expect(viewModel.visibleLimit == AllSessionsViewModel.pageSize)

        viewModel.loadMore(upTo: viewModel.filteredSessions.count)
        #expect(viewModel.visibleLimit == AllSessionsViewModel.pageSize * 2)
        viewModel.loadMore(upTo: viewModel.filteredSessions.count)
        #expect(viewModel.visibleLimit == 63)

        viewModel.searchText = "paged"
        #expect(viewModel.filteredSessions.count == 60)
        #expect(viewModel.visibleLimit == AllSessionsViewModel.pageSize)
    }

    @Test("ZCode 归类后进入项目筛选且再次空 cwd upsert 不丢失")
    func zcodeAssignmentPersists() async throws {
        let env = try makeEnvironment()
        let viewModel = AllSessionsViewModel()
        viewModel.load(from: env.container)
        let session = try #require(viewModel.allSessions.first { $0.toolSessionId == "z-unclassified" })
        let project = try #require(viewModel.projects.first { $0.stableId == "project-a" })

        try await viewModel.assign(session, to: project, in: env.container)
        viewModel.scope = .project(project.id)
        #expect(viewModel.filteredSessions.map(\.toolSessionId).contains("z-unclassified"))

        let writer = SessionIndexWriter(modelContainer: env.container)
        try await writer.upsert(
            tool: "zcode", toolSessionId: "z-unclassified",
            sourcePath: "/tmp/z-unclassified.jsonl", projectCwd: "",
            startedAt: Date(), updatedAt: Date(), messageCount: 2,
            title: nil, preview: "after refresh"
        )
        #expect(try await writer.fetchProjectStableId(identityKey: "zcode:z-unclassified") == "project-a")
        #expect(try await writer.fetchCwd(identityKey: "zcode:z-unclassified") == "/tmp/project-a")
    }

    private func makeEnvironment() throws -> (container: ModelContainer, project: Project) {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let project = Project(stableId: "project-a", name: "项目甲", path: "/tmp/project-a")
        context.insert(project)
        context.insert(SessionIndex(
            tool: "claude-code", toolSessionId: "claude-1",
            sourcePath: "/tmp/claude.jsonl", projectCwd: project.path,
            startedAt: Date(timeIntervalSince1970: 300), updatedAt: Date(timeIntervalSince1970: 300),
            messageCount: 4, title: "修复登录", preview: "登录摘要", project: project
        ))
        context.insert(SessionIndex(
            tool: "zcode", toolSessionId: "z-classified",
            sourcePath: "/tmp/z-classified.jsonl", projectCwd: project.path,
            startedAt: Date(timeIntervalSince1970: 200), updatedAt: Date(timeIntervalSince1970: 200),
            messageCount: 2, title: nil, preview: "classified", project: project
        ))
        context.insert(SessionIndex(
            tool: "zcode", toolSessionId: "z-unclassified",
            sourcePath: "/tmp/z-unclassified.jsonl", projectCwd: "",
            startedAt: Date(timeIntervalSince1970: 100), updatedAt: Date(timeIntervalSince1970: 100),
            messageCount: 1, title: nil, preview: "unclassified"
        ))
        try context.save()
        return (container, project)
    }
}
