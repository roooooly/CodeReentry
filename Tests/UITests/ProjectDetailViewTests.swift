import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("ProjectDetail Router")
@MainActor
struct ProjectDetailViewTests {

    @Test("默认 tab 是 tools")
    func defaultTabIsTools() {
        let router = ProjectRouter()
        #expect(router.selectedTab == .tools)
    }

    @Test("select 切换 tab")
    func selectChangesTab() {
        let router = ProjectRouter()
        router.select(.sessions)
        #expect(router.selectedTab == .sessions)
        router.select(.memory)
        #expect(router.selectedTab == .memory)
    }

    @Test("select 切换到任意 tab（P2 全部启用）")
    func selectSwitchesAny() {
        let router = ProjectRouter()
        router.select(.ops)
        #expect(router.selectedTab == .ops)
        router.select(.platforms)
        #expect(router.selectedTab == .platforms)
    }

    @Test("关闭当前 tab 后回退首个启用项，且不能切到已关闭项")
    func disabledSelectionFallsBack() {
        let router = ProjectRouter()
        router.select(.ops)

        router.reconcile(enabledTabs: [.sessions, .memory])
        #expect(router.selectedTab == .sessions)

        router.select(.tools, enabledTabs: [.sessions, .memory])
        #expect(router.selectedTab == .sessions)
        router.select(.memory, enabledTabs: [.sessions, .memory])
        #expect(router.selectedTab == .memory)
    }

    @Test("DetailTab placeholderStage 全部 nil（P1/P2 已实现）")
    func tabAvailabilityMetadata() {
        for tab in DetailTab.allCases {
            #expect(tab.placeholderStage == nil)
        }
    }

    @Test("全部 6 个 tab enabled")
    func tabEnabledStates() {
        for tab in DetailTab.allCases {
            #expect(tab.isEnabled == true)
        }
    }

    @Test("DetailTab.allCases 顺序为 Tools/Sessions/Memory/Subs/Platforms/Ops")
    func tabBarOrder() {
        #expect(DetailTab.allCases == [.tools, .sessions, .memory, .subscriptions, .platforms, .ops])
    }

    @Test("项目路径检查只接受存在的目录")
    func projectPathAvailability() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-detail-path-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-a-project.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        #expect(ProjectPathAvailability.evaluate(path: directory.path) == .available)
        #expect(ProjectPathAvailability.evaluate(path: file.path) == .missing)
        #expect(ProjectPathAvailability.evaluate(path: directory.appendingPathComponent("gone").path) == .missing)
    }

    @Test("项目头部读屏信息包含最近提交与路径失效状态")
    func headerIncludesCommitAndMissingPath() {
        let project = Project(stableId: "detail", name: "DevHub", path: "/missing/devhub")
        let header = ProjectDetailHeader(
            project: project,
            gitStatus: GitStatus(
                branch: "main",
                lastCommitSubject: "finish relocation",
                dirtyFileCount: 0
            ),
            pathAvailability: .missing
        )

        #expect(header.headerAccessibility.contains(String(localized: "项目路径已失效")))
        #expect(header.headerAccessibility.contains("finish relocation"))
    }
}
