import Foundation
import SwiftData
import DevHubCore

/// 菜单栏打开项目时也要写入 lastOpenedAt，使“最近项目”排序与侧边栏行为一致。
@MainActor
enum MenuBarProjectSelectionRecorder {
    @discardableResult
    static func markOpened(
        stableId: String,
        at date: Date = Date(),
        modelContext: ModelContext
    ) throws -> Bool {
        let requestedId = stableId
        var descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.stableId == requestedId }
        )
        descriptor.fetchLimit = 1
        guard let project = try modelContext.fetch(descriptor).first else { return false }
        try ProjectRegistry(modelContext: modelContext).markOpened(id: project.id, at: date)
        return true
    }
}
