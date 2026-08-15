import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("SidebarViewModel")
@MainActor
struct SidebarViewTests {

    @Test("项目按 置顶/活跃/归档 分组")
    func projectsGroupedCorrectly() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        for p in ProjectFixtures.makeProjects() { ctx.insert(p) }
        try ctx.save()

        let vm = SidebarViewModel()
        vm.loadProjects(from: ctx)

        // 置顶 3 个
        #expect(vm.pinnedProjects.map(\.name).sorted() == ["ExampleApp", "developer-tools", "sample-workspace"])
        // 活跃分组按 group 名聚合：Active 组 2 个
        let activeGroup = vm.activeGroups.first { $0.name == "Active" }
        #expect(activeGroup?.projects.count == 2)
        // 归档：group == "Archive" 的归入 archiveProjects
        #expect(vm.archivedProjects.count == 1)
        #expect(vm.archivedProjects.first?.name == "archived-demo")
    }

    @Test("group==nil 且非 pinned 非 archive 的项目归入默认活跃组")
    func ungroupedActiveProjects() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        let p = ProjectFixtures.makeProject(
            name: "lonely", path: "/x/lonely",
            isPinned: false, group: nil, tags: []
        )
        ctx.insert(p)
        try ctx.save()

        let vm = SidebarViewModel()
        vm.loadProjects(from: ctx)

        let defaultGroup = vm.activeGroups.first { $0.name == SidebarViewModel.defaultGroupName }
        #expect(defaultGroup?.projects.count == 1)
    }

    @Test("拖入文件夹路径 → 调用 ProjectRegistry.register(name:path:stableId:)")
    func registerDroppedFolderDelegatesToRegistry() throws {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let deps = AppDependencies(modelContainer: container)
        let vm = SidebarViewModel()

        // 在临时目录造一个真目录
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let project = try vm.registerDroppedFolder(at: tmp.path, deps: deps, ctx: ctx)
        #expect(project.path == (tmp.path as NSString).standardizingPath)
        #expect(project.stableId.isEmpty == false)
        #expect(project.name == tmp.lastPathComponent)  // 名称由路径末段推导
    }

    @Test("重复拖入同一路径 → 抛 duplicatePath")
    func registerDroppedFolderDuplicateThrows() throws {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let deps = AppDependencies(modelContainer: container)
        let vm = SidebarViewModel()

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-dup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        _ = try vm.registerDroppedFolder(at: tmp.path, deps: deps, ctx: ctx)
        #expect(throws: ProjectRegistryError.duplicatePath) {
            try vm.registerDroppedFolder(at: tmp.path, deps: deps, ctx: ctx)
        }
    }

    @Test("分组与标签输入会清理空白、空项和重复值")
    func organizationInputNormalization() {
        #expect(SidebarViewModel.normalizedGroup("  客户端  ") == "客户端")
        #expect(SidebarViewModel.normalizedGroup("  \n") == nil)
        #expect(
            SidebarViewModel.normalizedTags(" swift, macOS，swift\n  本地  ,, ")
                == ["swift", "macOS", "本地"]
        )
    }

    @Test("选择项目会更新 lastOpenedAt")
    func selectionRecordsLastOpenedTime() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        let deps = AppDependencies(modelContainer: container)
        let project = ProjectFixtures.makeProject(name: "Recent", path: "/tmp/recent")
        ctx.insert(project)
        try ctx.save()

        let vm = SidebarViewModel()
        vm.loadProjects(from: ctx)
        let openedAt = Date(timeIntervalSince1970: 1_733_333_333)

        try vm.markOpened(stableId: project.stableId, at: openedAt, deps: deps, ctx: ctx)

        #expect(project.lastOpenedAt == openedAt)
    }

    @Test("侧边栏组织操作通过 ProjectRegistry 持久化")
    func organizationPersists() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        let deps = AppDependencies(modelContainer: container)
        let project = ProjectFixtures.makeProject(name: "Organized", path: "/tmp/organized")
        ctx.insert(project)
        try ctx.save()
        let vm = SidebarViewModel()
        vm.loadProjects(from: ctx)

        try vm.setPinned(true, projectId: project.id, deps: deps, ctx: ctx)
        try vm.updateOrganization(
            projectId: project.id,
            group: " 客户端 ",
            tags: "swift, macOS, swift",
            deps: deps,
            ctx: ctx
        )

        #expect(project.isPinned)
        #expect(project.group == "客户端")
        #expect(project.tags == ["swift", "macOS"])
    }

    @Test("确认移除后会注销项目并清空待确认状态")
    func removalPersists() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        let deps = AppDependencies(modelContainer: container)
        let project = ProjectFixtures.makeProject(name: "Remove Me", path: "/tmp/remove-me")
        ctx.insert(project)
        try ctx.save()
        let vm = SidebarViewModel()
        vm.loadProjects(from: ctx)
        vm.requestRemoval(of: project)
        let removal = try #require(vm.pendingRemoval)

        try vm.removeProject(removal, deps: deps, ctx: ctx)

        #expect(try ctx.fetch(FetchDescriptor<Project>()).isEmpty)
        #expect(vm.pendingRemoval == nil)
    }

    @Test("失效项目路径会进入警告状态，重新定位后恢复")
    func missingPathCanBeRelocated() throws {
        let container = try Self.makeContainer()
        let ctx = container.mainContext
        let deps = AppDependencies(modelContainer: container)
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-sidebar-missing-\(UUID().uuidString)")
        let project = Project(
            stableId: "sidebar-moved",
            name: "Moved",
            path: missingPath.path
        )
        ctx.insert(project)
        try ctx.save()

        let vm = SidebarViewModel()
        vm.loadProjects(from: ctx)
        #expect(vm.isPathMissing(for: project))

        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-sidebar-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: target) }

        try vm.relocateProject(id: project.id, to: target.path, deps: deps, ctx: ctx)

        #expect(!vm.isPathMissing(for: project))
        #expect(project.path == (target.path as NSString).standardizingPath)
        #expect(try PathLocator.readStableId(at: target) == "sidebar-moved")
    }

    // MARK: - helpers

    /// 返回内存型 ModelContainer（**调用方必须保持 container 存活**，
    /// 否则 mainContext 指向已释放的 container → SwiftData trap）。
    static func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }
}
