import Foundation
import SwiftData
import OSLog
import DevHubCore

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "sessions-tab")

/// 每个工具的着色（spec §5.3 按工具着色）
enum ToolColor {
    static func color(for toolId: String) -> String {
        switch toolId {
        case "claude-code": return "orange"
        case "codex":       return "green"
        case "zcode":       return "blue"
        case "kimi":        return "purple"
        default:            return "gray"
        }
    }
}

struct SessionToolGroup: Identifiable {
    let tool: String
    let sessions: [SessionIndex]
    var id: String { tool }
}

@Observable
@MainActor
final class SessionsTabViewModel {
    private(set) var allSessions: [SessionIndex] = []
    var searchText: String = ""
    /// 空串 = 全部
    var toolFilter: String = ""

    /// 「在原工具中继续」委托（View 注入生产实现：解析 adapter → resume）。
    var resumeHandler: (@MainActor (SessionIndex) async throws -> Void)?
    /// 「生成总结」委托，返回生成的 markdown（View 注入生产实现：
    /// SessionReader.load → SummaryExtractor.extractSummary → MemoryStore.write）。
    var generateSummaryHandler: (@MainActor (SessionIndex) async throws -> Void)?

    var isEmpty: Bool { allSessions.isEmpty }

    func load(project: Project, from ctx: ModelContext) {
        let targetId = project.id
        let descriptor = FetchDescriptor<SessionIndex>(
            predicate: #Predicate { $0.project?.id == targetId },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        allSessions = (try? ctx.fetch(descriptor)) ?? []
    }

    var filteredSessions: [SessionIndex] {
        var result = allSessions
        if !toolFilter.isEmpty {
            result = result.filter { $0.tool == toolFilter }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return result }
        return result.filter { SessionSearch.matches($0, normalizedQuery: q) }
    }

    var toolGroups: [SessionToolGroup] {
        let filtered = filteredSessions
        let grouped = Dictionary(grouping: filtered, by: { $0.tool })
        return grouped
            .map { SessionToolGroup(tool: $0.key, sessions: $0.value) }
            .sorted { $0.tool < $1.tool }
    }

    var availableTools: [String] {
        Array(Set(allSessions.map(\.tool))).sorted()
    }

    /// 在原工具中继续。委托 resumeHandler；未注入则记日志返回。
    func resumeInOriginalTool(_ session: SessionIndex) async throws {
        guard let handler = resumeHandler else {
            logger.warning("resumeHandler 未注入，无法 resume tool=\(session.tool, privacy: .public)")
            return
        }
        try await handler(session)
    }

    /// 生成本会话总结（触发型——内部走 reader+SummaryExtractor+MemoryStore）。
    func generateSummary(for session: SessionIndex) async throws {
        if let handler = generateSummaryHandler {
            try await handler(session)
            return
        }
        logger.info("无 handler，跳过总结 sid=\(session.toolSessionId, privacy: .public)")
    }
}

enum SessionSearch {
    /// P0 只检索 SwiftData 已缓存字段，不读取原始 JSONL。
    /// 与设计 §5.3 一致覆盖标题、摘要、工具与原始会话 ID。
    static func matches(_ session: SessionIndex, normalizedQuery query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return (session.title?.lowercased().contains(query) ?? false)
            || session.preview.lowercased().contains(query)
            || session.tool.lowercased().contains(query)
            || session.toolSessionId.lowercased().contains(query)
    }
}
