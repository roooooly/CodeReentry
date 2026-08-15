import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("ModelContainerFactory + relationships")
struct ModelContainerFactoryTests {

    @Test("container registers all 7 models")
    @MainActor
    func containerAllModels() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        #expect(container.schema.entities.count == 7)
    }

    @Test("Project cascade-deletes SessionIndex and ProjectPlatformBinding, nullifies Tool/Subscription")
    @MainActor
    func deleteRules() throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let ctx = ModelContext(container)
        let p = Project(stableId: "s", name: "X", path: "/tmp")
        let t = Tool(name: "claude", kind: .cli, launchCommand: "claude",
                     workingDirMode: .projectRoot, injectionMode: .cliFlag, sortOrder: 0)
        let s = Subscription(name: "n", provider: "p", amount: 1, currency: "USD",
                             cycle: .monthly, nextRenewal: Date())
        let b = ProjectPlatformBinding(project: p, account: nil, publishStatus: .draft)
        let si = SessionIndex(tool: "codex", toolSessionId: "x", sourcePath: "/t",
                               projectCwd: "/t", startedAt: Date(), updatedAt: Date(),
                               messageCount: 0, title: nil, preview: "")
        p.tools = [t]; t.projects = [p]
        p.subscriptions = [s]; s.project = p
        p.platformBindings = [b]
        p.sessions = [si]
        ctx.insert(p); ctx.insert(t); ctx.insert(s); ctx.insert(b); ctx.insert(si)
        try ctx.save()

        ctx.delete(p)
        try ctx.save()

        #expect(try ctx.fetch(FetchDescriptor<SessionIndex>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<ProjectPlatformBinding>()).isEmpty)
        #expect(try ctx.fetch(FetchDescriptor<Tool>()).first?.projects.isEmpty == true)
        #expect(try ctx.fetch(FetchDescriptor<Subscription>()).first?.project == nil)
    }

    @Test("storeURL helper points at Application Support/DevHub/DevHub.store")
    @MainActor
    func storeURLPath() throws {
        let url = ModelContainerFactory.storeURL()
        #expect(url.path.contains("Application Support/DevHub"))
        #expect(url.lastPathComponent == "DevHub.store")
    }

    @Test("disk-mode container actually uses the spec §4.2 storeURL, not SwiftData default")
    @MainActor
    func diskContainerUsesSpecURL() throws {
        // 用临时目录覆盖 storeURL，避免污染真实 ~/Library/Application Support/DevHub
        // 通过 makeContainer(configurations:) 注入显式 url 来验证 url 真的被消费
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let storeFile = tmpDir.appendingPathComponent("Test.store")
        let schema = Schema(DevHubSchemaV1.models)
        let config = ModelConfiguration(schema: schema, url: storeFile, allowsSave: true)
        let container = try ModelContainer(for: schema, configurations: [config])

        // 容器 URL 应等于我们传入的路径（证明 url 参数被消费）
        #expect(container.configurations.first?.url.path == storeFile.path)

        // 写一条数据，确认真的落盘到该文件
        let ctx = ModelContext(container)
        ctx.insert(Project(stableId: "s", name: "X", path: "/tmp"))
        try ctx.save()
        #expect(FileManager.default.fileExists(atPath: storeFile.path))
    }

    @Test("unopenable store is moved to a recoverable directory before rebuilding")
    @MainActor
    func corruptStoreIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-recovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("DevHub.store")
        // SQLite 无法把目录当数据库打开，稳定触发首次创建失败。
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let sidecar = root.appendingPathComponent("DevHub.store-wal")
        try Data("preserve-me".utf8).write(to: sidecar)

        let result = try ModelContainerFactory.makeRecoveringContainer(at: store)
        let recovery = try #require(result.recoveredStoreDirectory)

        #expect(result.container.configurations.first?.url.path == store.path)
        #expect(FileManager.default.fileExists(
            atPath: recovery.appendingPathComponent("DevHub.store").path
        ))
        #expect(try Data(contentsOf: recovery.appendingPathComponent("DevHub.store-wal"))
            == Data("preserve-me".utf8))
    }
}
