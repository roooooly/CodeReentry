import Foundation
import SwiftUI
import OSLog
import DevHubCore

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "memory-tab")

@Observable
@MainActor
final class MemoryTabViewModel {
    static var starterTemplate: String {
        [
            String(localized: "# 项目目标"),
            String(localized: "- 这个项目解决什么问题："),
            "",
            String(localized: "# 当前约束"),
            String(localized: "- 技术、兼容性或交付边界："),
            "",
            String(localized: "# 关键命令"),
            String(localized: "- 启动："),
            String(localized: "- 测试："),
            "",
            String(localized: "# 当前状态与下一步"),
            String(localized: "- 已完成："),
            String(localized: "- 下一步：")
        ].joined(separator: "\n") + "\n"
    }

    var contextMd: String = ""
    var lastSummaryMd: String = ""
    var hasLastSummary: Bool = false
    var dirty: Bool = false
    var isPreview: Bool = false
    var loadError: String?
    var saveError: String?

    private struct DocumentTarget: Equatable, Sendable {
        let projectID: String
        let projectPath: String
    }

    private enum SaveError: LocalizedError {
        case noLoadedProject

        var errorDescription: String? {
            switch self {
            case .noLoadedProject:
                return String(localized: "尚未加载可保存的项目记忆。")
            }
        }
    }

    static let defaultAutosaveDelayNanoseconds: UInt64 = 800_000_000

    private var lastSavedContext: String = ""
    private var documentTarget: DocumentTarget?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?

    var loadedProjectID: String? { documentTarget?.projectID }
    var loadedProjectPath: String? { documentTarget?.projectPath }

    func load(projectID: String, projectPath: String, deps: AppDependencies) throws {
        cancelScheduledAutosave()
        do {
            let store = deps.memoryStore(forProjectPath: projectPath)
            let loadedContext = try store.readContext()
            let loadedSummary = try store.readLastSessionSummary()

            // Only publish the new document after both reads succeed. A failed project
            // switch must not retarget the previous draft to the newly selected project.
            documentTarget = DocumentTarget(projectID: projectID, projectPath: projectPath)
            contextMd = loadedContext
            lastSavedContext = loadedContext
            lastSummaryMd = loadedSummary ?? ""
            hasLastSummary = !(loadedSummary ?? "").isEmpty
            dirty = false
            loadError = nil
            saveError = nil
        } catch {
            logger.error("加载项目记忆失败: \(error.localizedDescription, privacy: .public)")
            loadError = error.localizedDescription
            throw error
        }
    }

    /// Activates a project document. When SwiftUI reuses this ViewModel during a
    /// project switch, the previous draft is flushed to its own bound path first.
    /// If that write fails, activation stops and the draft remains available for retry.
    func activate(projectID: String, projectPath: String, deps: AppDependencies) {
        let requestedTarget = DocumentTarget(projectID: projectID, projectPath: projectPath)
        guard documentTarget != requestedTarget || loadError != nil else { return }

        if documentTarget != nil, documentTarget != requestedTarget,
           !flushPendingSave(deps: deps) {
            return
        }

        do {
            try load(projectID: projectID, projectPath: projectPath, deps: deps)
        } catch {
            // load(projectID:projectPath:deps:) owns the user-visible error state.
        }
    }

    /// Saves only to the project target captured by the successful load. Callers do
    /// not supply a path, so a newly selected project can never receive an old draft.
    func save(deps: AppDependencies) throws {
        guard let target = documentTarget else { throw SaveError.noLoadedProject }
        let savedContext = contextMd
        try deps.memoryStore(forProjectPath: target.projectPath).writeContext(savedContext)
        lastSavedContext = savedContext
        dirty = contextMd != lastSavedContext
        saveError = nil
        logger.info("项目记忆已保存 path=\(target.projectPath, privacy: .private(mask: .hash))")
    }

    /// Schedules a trailing-edge autosave tied to the currently loaded project.
    /// A stale task is harmless even if cancellation races with a project switch,
    /// because the captured target must still match before writing.
    func scheduleAutosave(
        deps: AppDependencies,
        delayNanoseconds: UInt64 = defaultAutosaveDelayNanoseconds
    ) {
        cancelScheduledAutosave()
        guard dirty, let expectedTarget = documentTarget else { return }

        autosaveTask = Task { @MainActor [weak self, weak deps] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            guard let self, let deps, !Task.isCancelled,
                  self.documentTarget == expectedTarget else { return }
            _ = self.attemptSave(deps: deps, expectedTarget: expectedTarget)
        }
    }

    /// Cancels a pending debounce and synchronously commits the current draft. This
    /// is used by the Save button and onDisappear, so navigation cannot beat the timer.
    @discardableResult
    func flushPendingSave(deps: AppDependencies) -> Bool {
        cancelScheduledAutosave()
        guard let target = documentTarget else { return !dirty }
        return attemptSave(deps: deps, expectedTarget: target)
    }

    private func attemptSave(deps: AppDependencies, expectedTarget: DocumentTarget) -> Bool {
        guard documentTarget == expectedTarget else { return false }
        guard dirty else { return true }
        do {
            try save(deps: deps)
            return true
        } catch {
            saveError = error.localizedDescription
            logger.error("保存项目记忆失败: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func cancelScheduledAutosave() {
        autosaveTask?.cancel()
        autosaveTask = nil
    }

    /// 由 View 在 TextEditor `.onChange(of: contextMd)` 中调用——
    /// @Observable 属性的 didSet 不可靠，故 dirty 判定走显式方法。
    func markDirtyIfNeeded() {
        dirty = contextMd != lastSavedContext
    }

    /// Only inserts into an empty document; never overwrites existing project knowledge.
    @discardableResult
    func insertStarterTemplate() -> Bool {
        guard contextMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        contextMd = Self.starterTemplate
        markDirtyIfNeeded()
        return true
    }

    var renderedPreview: AttributedString {
        if let parsed = try? AttributedString(markdown: contextMd,
                                              options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return parsed
        }
        return AttributedString(contextMd)
    }
}
