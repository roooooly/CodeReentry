import Testing
import Foundation
import AppKit
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("MenuBarViewModel")
@MainActor
struct MenuBarViewModelTests {

    @Test("refresh 拉取 provider 提供的最近项目")
    func refreshPullsRecent() async {
        let items = [
            MenuBarItem(id: UUID(), name: "C", path: "/C", stableId: "s3"),
            MenuBarItem(id: UUID(), name: "B", path: "/B", stableId: "s2"),
        ]
        let vm = MenuBarViewModel(topN: 5) { items }
        await vm.refresh()
        #expect(vm.recentProjects.count == 2)
        #expect(vm.recentProjects.first?.name == "C")
        #expect(vm.activeProjectName == "C")
    }

    @Test("provider 返回空 → activeProjectName nil")
    func emptyNoActive() async {
        let vm = MenuBarViewModel(topN: 5) { [] }
        await vm.refresh()
        #expect(vm.recentProjects.isEmpty)
        #expect(vm.activeProjectName == nil)
    }

    @Test("打开应用和最近项目都调用主窗口展示器")
    func menuActionsPresentMainWindow() {
        let controller = MenuBarController(viewModel: MenuBarViewModel(topN: 5) { [] })
        var showCount = 0
        var selectedProject: String?
        controller.onShowApp = { showCount += 1 }
        controller.onSelectProject = { selectedProject = $0 }

        controller.showApp()
        #expect(showCount == 1)

        let item = NSMenuItem(title: "Project", action: nil, keyEquivalent: "")
        item.representedObject = "stable-project"
        controller.openProject(item)
        #expect(selectedProject == "stable-project")
        #expect(showCount == 2)
    }

    @Test("无可见窗口时主窗口展示器调用 SwiftUI openWindow")
    func presenterOpensSceneWithoutRegisteredWindow() {
        let presenter = MainWindowPresenter()
        var openCount = 0
        presenter.register(openWindow: { openCount += 1 })

        presenter.show()

        #expect(openCount == 1)
    }

    @Test("refresh 多次取最新")
    func refreshUpdates() async {
        var items = [MenuBarItem(id: UUID(), name: "A", path: "/A", stableId: "s1")]
        let vm = MenuBarViewModel(topN: 5) { items }
        await vm.refresh()
        #expect(vm.activeProjectName == "A")

        items = [
            MenuBarItem(id: UUID(), name: "Z", path: "/Z", stableId: "s9"),
            MenuBarItem(id: UUID(), name: "A", path: "/A", stableId: "s1"),
        ]
        await vm.refresh()
        #expect(vm.activeProjectName == "Z")
        #expect(vm.recentProjects.count == 2)
    }

    @Test("项目新增、最近打开和移除通知都会刷新菜单数据")
    func projectChangesRefreshMenuData() async throws {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let context = container.mainContext
        let first = Project(
            stableId: "first",
            name: "First",
            path: "/tmp/first",
            lastOpenedAt: Date(timeIntervalSince1970: 100)
        )
        context.insert(first)
        try context.save()

        let center = NotificationCenter()
        let vm = MenuBarViewModel(topN: 5) {
            var descriptor = FetchDescriptor<Project>(
                sortBy: [SortDescriptor(\.lastOpenedAt, order: .reverse)]
            )
            descriptor.fetchLimit = 5
            return (try? context.fetch(descriptor))?.compactMap { project in
                guard project.lastOpenedAt != nil else { return nil }
                return MenuBarItem(
                    id: project.id,
                    name: project.name,
                    path: project.path,
                    stableId: project.stableId
                )
            } ?? []
        }
        let controller = MenuBarController(viewModel: vm, notificationCenter: center)
        await controller.refreshAndRebuild()
        #expect(vm.recentProjects.map(\.stableId) == ["first"])

        let second = Project(
            stableId: "second",
            name: "Second",
            path: "/tmp/second",
            lastOpenedAt: Date(timeIntervalSince1970: 200)
        )
        context.insert(second)
        try context.save()
        center.post(name: MenuBarController.projectsChangedNotification, object: nil)
        try await waitUntil { vm.recentProjects.count == 2 }
        #expect(vm.activeProjectName == "Second")

        let changed = try MenuBarProjectSelectionRecorder.markOpened(
            stableId: first.stableId,
            at: Date(timeIntervalSince1970: 300),
            modelContext: context
        )
        #expect(changed)
        center.post(name: MenuBarController.projectsChangedNotification, object: nil)
        try await waitUntil { vm.activeProjectName == "First" }

        context.delete(first)
        try context.save()
        center.post(name: MenuBarController.projectsChangedNotification, object: nil)
        try await waitUntil { vm.recentProjects.map(\.stableId) == ["second"] }
    }

    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("等待菜单刷新超时")
    }
}
