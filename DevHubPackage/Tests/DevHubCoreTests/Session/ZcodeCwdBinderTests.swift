import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("ZcodeCwdBinder")
struct ZcodeCwdBinderTests {

    @MainActor
    @Test("assign 写入 SessionIndex.projectCwd")
    func assignCwd() async throws {
        let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SessionIndex.self, Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self, AppSettings.self,
            configurations: cfg
        )
        let writer = SessionIndexWriter(modelContainer: container)
        // 先 upsert 一条 zcode 会话（带 identityKey "zcode:sess_x"）
        try await writer.upsert(
            tool: "zcode", toolSessionId: "sess_x",
            sourcePath: "/tmp/x.jsonl", projectCwd: "",
            startedAt: Date(), updatedAt: Date(),
            messageCount: 1, title: nil, preview: ""
        )

        let binder = ZcodeCwdBinder(writer: writer)
        let ok = try await binder.assign(toolSessionId: "sess_x", cwd: "/Users/example/ExampleApp")
        #expect(ok == true)
        let fetched = try await writer.fetchCwd(identityKey: "zcode:sess_x")
        #expect(fetched == "/Users/example/ExampleApp")
    }

    @MainActor
    @Test("assign 不存在的会话返回 false")
    func assignMissing() async throws {
        let cfg = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: SessionIndex.self, Project.self,
            configurations: cfg
        )
        let writer = SessionIndexWriter(modelContainer: container)
        let binder = ZcodeCwdBinder(writer: writer)
        let ok = try await binder.assign(toolSessionId: "ghost", cwd: "/x")
        #expect(ok == false)
    }

    @MainActor
    @Test("按 stableId 归类会同时保存项目关系和 cwd")
    func assignProject() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let project = Project(stableId: "project-a", name: "A", path: "/tmp/project-a")
        container.mainContext.insert(project)
        try container.mainContext.save()

        let writer = SessionIndexWriter(modelContainer: container)
        try await writer.upsert(
            tool: "zcode", toolSessionId: "sess_project",
            sourcePath: "/tmp/zcode.jsonl", projectCwd: "",
            startedAt: Date(), updatedAt: Date(),
            messageCount: 1, title: nil, preview: ""
        )

        let binder = ZcodeCwdBinder(writer: writer)
        #expect(try await binder.assign(toolSessionId: "sess_project", projectStableId: "project-a"))
        #expect(try await writer.fetchCwd(identityKey: "zcode:sess_project") == "/tmp/project-a")
        #expect(try await writer.fetchProjectStableId(identityKey: "zcode:sess_project") == "project-a")
    }

    @MainActor
    @Test("reader 再次返回空 cwd 时保留用户归类")
    func emptyCwdUpsertPreservesManualAssignment() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let project = Project(stableId: "project-a", name: "A", path: "/tmp/project-a")
        container.mainContext.insert(project)
        try container.mainContext.save()
        let writer = SessionIndexWriter(modelContainer: container)
        try await writer.upsert(
            tool: "zcode", toolSessionId: "sess_keep",
            sourcePath: "/tmp/zcode.jsonl", projectCwd: "",
            startedAt: Date(), updatedAt: Date(), messageCount: 1, title: nil, preview: ""
        )
        _ = try await writer.assignProject(identityKey: "zcode:sess_keep", projectStableId: "project-a")

        try await writer.upsert(
            tool: "zcode", toolSessionId: "sess_keep",
            sourcePath: "/tmp/zcode.jsonl", projectCwd: "",
            startedAt: Date(), updatedAt: Date(), messageCount: 2, title: nil, preview: "new"
        )

        #expect(try await writer.fetchCwd(identityKey: "zcode:sess_keep") == "/tmp/project-a")
        #expect(try await writer.fetchProjectStableId(identityKey: "zcode:sess_keep") == "project-a")
    }
}
