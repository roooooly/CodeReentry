import Foundation
import Observation

struct MenuBarItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let path: String
    let stableId: String
}

@MainActor
@Observable
final class MenuBarViewModel {
    let topN: Int
    var recentProjects: [MenuBarItem] = []
    var activeProjectName: String?

    /// 最近项目数据源（View 注入：从 ModelContext 按 lastOpenedAt 降序取 topN）。
    private let recentProvider: () async -> [MenuBarItem]

    init(topN: Int = 5, recentProvider: @escaping () async -> [MenuBarItem]) {
        self.topN = topN
        self.recentProvider = recentProvider
    }

    func refresh() async {
        let recent = await recentProvider()
        recentProjects = recent
        activeProjectName = recent.first?.name
    }
}
