import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("MemoryTab ViewModel")
@MainActor
struct MemoryTabTests {

    @Test("加载时读 context.md + last-session-summary.md")
    func loadReadsBothFiles() throws {
        let env = try MemoryTabTests.makeMemoryEnv(contextMd: "# 标题\n正文", summaryMd: "上次会话摘要")
        let vm = MemoryTabViewModel()
        try vm.load(projectID: env.projectID, projectPath: env.projectPath, deps: env.deps)

        #expect(vm.contextMd == "# 标题\n正文")
        #expect(vm.lastSummaryMd == "上次会话摘要")
        #expect(vm.hasLastSummary == true)
    }

    @Test("summary 不存在 → hasLastSummary=false")
    func noSummary() throws {
        let env = try MemoryTabTests.makeMemoryEnv(contextMd: "x", summaryMd: nil)
        let vm = MemoryTabViewModel()
        try vm.load(projectID: env.projectID, projectPath: env.projectPath, deps: env.deps)
        #expect(vm.hasLastSummary == false)
    }

    @Test("保存 context.md → 写回磁盘（再读一致）")
    func saveWrites() throws {
        let env = try MemoryTabTests.makeMemoryEnv(contextMd: "初始", summaryMd: nil)
        let vm = MemoryTabViewModel()
        try vm.load(projectID: env.projectID, projectPath: env.projectPath, deps: env.deps)

        vm.contextMd = "改后内容"
        vm.markDirtyIfNeeded()
        try vm.save(deps: env.deps)

        #expect(vm.dirty == false)
        // 直接从 store 再读验证落盘
        let reread = try env.deps.memoryStore(forProjectPath: env.projectPath).readContext()
        #expect(reread == "改后内容")
    }

    @Test("contextMd 修改后 dirty=true；保存后 dirty=false")
    func dirtyTracking() throws {
        let env = try MemoryTabTests.makeMemoryEnv(contextMd: "初始", summaryMd: nil)
        let vm = MemoryTabViewModel()
        try vm.load(projectID: env.projectID, projectPath: env.projectPath, deps: env.deps)

        #expect(vm.dirty == false)
        vm.contextMd += " 修改"
        vm.markDirtyIfNeeded()
        #expect(vm.dirty == true)
        try vm.save(deps: env.deps)
        #expect(vm.dirty == false)
    }

    @Test("去抖自动保存会落盘并清除 dirty", .timeLimit(.minutes(1)))
    func debouncedAutosaveWrites() async throws {
        let env = try MemoryTabTests.makeMemoryEnv(contextMd: "初始", summaryMd: nil)
        defer { try? FileManager.default.removeItem(atPath: env.projectPath) }
        let vm = MemoryTabViewModel()
        try vm.load(projectID: env.projectID, projectPath: env.projectPath, deps: env.deps)

        vm.contextMd = "自动保存内容"
        vm.markDirtyIfNeeded()
        vm.scheduleAutosave(deps: env.deps, delayNanoseconds: 10_000_000)
        try await Task.sleep(nanoseconds: 100_000_000)

        let reread = try env.deps.memoryStore(forProjectPath: env.projectPath).readContext()
        #expect(reread == "自动保存内容")
        #expect(vm.dirty == false)
        #expect(vm.saveError == nil)
    }

    @Test("项目切换先保存旧项目，取消的旧去抖任务不能写入新项目", .timeLimit(.minutes(1)))
    func projectSwitchKeepsDraftBoundToOriginalProject() async throws {
        let deps = try MemoryTabTests.makeDependencies()
        let projectA = try MemoryTabTests.makeProject(contextMd: "A 初始")
        let projectB = try MemoryTabTests.makeProject(contextMd: "B 初始")
        defer {
            try? FileManager.default.removeItem(at: projectA)
            try? FileManager.default.removeItem(at: projectB)
        }
        let vm = MemoryTabViewModel()
        try vm.load(projectID: "project-a", projectPath: projectA.path, deps: deps)

        vm.contextMd = "A 草稿"
        vm.markDirtyIfNeeded()
        vm.scheduleAutosave(deps: deps, delayNanoseconds: 80_000_000)
        vm.activate(projectID: "project-b", projectPath: projectB.path, deps: deps)

        #expect(try deps.memoryStore(forProjectPath: projectA.path).readContext() == "A 草稿")
        #expect(try deps.memoryStore(forProjectPath: projectB.path).readContext() == "B 初始")
        #expect(vm.loadedProjectID == "project-b")
        #expect(vm.contextMd == "B 初始")

        // Leave B dirty without scheduling its own save. If the cancelled A task
        // wakes and targets the current document, this value would leak to B.
        vm.contextMd = "B 未请求保存的草稿"
        vm.markDirtyIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        #expect(try deps.memoryStore(forProjectPath: projectB.path).readContext() == "B 初始")
        #expect(vm.dirty)
    }

    @Test("旧项目保存失败会阻止切换、保留草稿并暴露错误")
    func failedFlushBlocksProjectSwitch() throws {
        let deps = try MemoryTabTests.makeDependencies()
        let projectA = try MemoryTabTests.makeProject(contextMd: "A 初始")
        let projectB = try MemoryTabTests.makeProject(contextMd: "B 初始")
        defer {
            try? FileManager.default.removeItem(at: projectA)
            try? FileManager.default.removeItem(at: projectB)
        }
        let vm = MemoryTabViewModel()
        try vm.load(projectID: "project-a", projectPath: projectA.path, deps: deps)

        vm.contextMd = "必须保留的 A 草稿"
        vm.markDirtyIfNeeded()
        try FileManager.default.removeItem(at: projectA)
        try Data("阻止创建目录".utf8).write(to: projectA)

        vm.activate(projectID: "project-b", projectPath: projectB.path, deps: deps)

        #expect(vm.loadedProjectID == "project-a")
        #expect(vm.contextMd == "必须保留的 A 草稿")
        #expect(vm.dirty)
        #expect(vm.saveError?.isEmpty == false)
        #expect(try deps.memoryStore(forProjectPath: projectB.path).readContext() == "B 初始")
    }

    @Test("preview 模式渲染 markdown 为非空 AttributedString")
    func previewRender() throws {
        let vm = MemoryTabViewModel()
        vm.contextMd = "# 标题"
        let attr = vm.renderedPreview
        #expect(attr.characters.isEmpty == false)
    }

    @Test("基础模板只写入空文档，不覆盖已有记忆")
    func starterTemplateIsSafe() {
        let vm = MemoryTabViewModel()
        #expect(vm.insertStarterTemplate())
        #expect(vm.contextMd.contains("# 项目目标"))
        #expect(vm.contextMd.contains("# 当前约束"))
        #expect(vm.dirty)

        vm.contextMd = "已有的重要内容"
        #expect(vm.insertStarterTemplate() == false)
        #expect(vm.contextMd == "已有的重要内容")
    }

    // MARK: - fixture

    struct MemoryEnv {
        let projectID: String
        let projectPath: String
        let deps: AppDependencies
    }

    static func makeMemoryEnv(contextMd: String, summaryMd: String?) throws -> MemoryEnv {
        let deps = try makeDependencies()
        let (factory, rootPath) = try TestMemoryFactory.make(contextMd: contextMd, summaryMd: summaryMd)
        deps.overrideServices(memoryStoreFactory: factory)
        return MemoryEnv(projectID: "test-project", projectPath: rootPath, deps: deps)
    }

    static func makeDependencies() throws -> AppDependencies {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return AppDependencies(modelContainer: container)
    }

    static func makeProject(contextMd: String, summaryMd: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-memory-project-\(UUID().uuidString)", isDirectory: true)
        let memoryDirectory = root
            .appendingPathComponent(".devhub", isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDirectory, withIntermediateDirectories: true)
        try contextMd.write(
            to: memoryDirectory.appendingPathComponent("context.md"),
            atomically: true,
            encoding: .utf8
        )
        if let summaryMd {
            try summaryMd.write(
                to: memoryDirectory.appendingPathComponent("last-session-summary.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }
}
