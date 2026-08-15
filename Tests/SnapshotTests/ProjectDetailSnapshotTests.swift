import Testing
import SwiftUI
import SwiftData
import SnapshotTesting
import DevHubCore
@testable import DevHub

/// Snapshot 回归测试（swift-snapshot-testing）。
/// 首次运行生成基线（__Snapshots__/），后续运行比对。
/// 运行 `xcodebuild test ... -only-testing:DevHubTests/ProjectDetailSnapshotTests`
/// 或在 Xcode 中按 ⌘U；首次会因无基线而"失败"并生成基线，commit 后即通过。
@Suite("ProjectDetailView Snapshots")
@MainActor
struct ProjectDetailSnapshotTests {

    private func makeDeps(container: ModelContainer) -> AppDependencies {
        let deps = AppDependencies(modelContainer: container)
        let tc = TerminalController()
        tc.executor = { _ in [:] }
        deps.overrideServices(terminalController: tc)
        return deps
    }

    @Test("tools tab 内置工具默认渲染")
    func toolsTabEmptySnapshot() throws {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-project-detail-snapshot")
        try? FileManager.default.removeItem(at: projectDirectory)
        try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projectDirectory) }
        let project = ProjectFixtures.makeProject(
            name: "ExampleApp",
            path: projectDirectory.path,
            isPinned: true,
            group: nil,
            tags: ["ai"]
        )
        ctx.insert(project)
        try ctx.save()

        let deps = makeDeps(container: container)
        let view = ProjectDetailView(projectStableId: project.stableId)
            .environment(deps)
            .modelContainer(container)
            .frame(width: 800, height: 600)
        let vc = NSHostingController(rootView: view)
        assertSnapshot(of: vc, as: .image(size: CGSize(width: 800, height: 600)), record: .missing)
    }
}
