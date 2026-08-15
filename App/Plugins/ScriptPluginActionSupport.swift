import Foundation
import SwiftData
import DevHubCore

enum ScriptPluginActionContextError: Error, LocalizedError, Equatable {
    case selectedProjectNotFound(String)

    var errorDescription: String? {
        switch self {
        case .selectedProjectNotFound:
            return String(localized: "当前选择的项目已被移除或无法读取，请重新选择项目。")
        }
    }
}

/// 将 UI 中保存的 stableId 解析为插件可消费的真实项目路径。
/// stableId 只是跨设备身份锚点，绝不能作为 cwd/projectPath 传给脚本。
@MainActor
enum ScriptPluginActionContextResolver {
    static func context(
        selectedProjectStableId: String?,
        selectedSessionId: String?,
        modelContext: ModelContext
    ) throws -> ScriptPluginContext {
        ScriptPluginContext(
            projectPath: try projectPath(
                selectedProjectStableId: selectedProjectStableId,
                modelContext: modelContext
            ),
            selectedSessionId: selectedSessionId
        )
    }

    static func projectPath(
        selectedProjectStableId: String?,
        modelContext: ModelContext
    ) throws -> String? {
        guard let stableId = selectedProjectStableId else { return nil }
        let requestedId = stableId
        var descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.stableId == requestedId }
        )
        descriptor.fetchLimit = 1
        guard let project = try modelContext.fetch(descriptor).first else {
            throw ScriptPluginActionContextError.selectedProjectNotFound(stableId)
        }
        return project.path
    }
}

enum ScriptPluginActionFeedback {
    private static let detailLimit = 2_000

    static func resultMessage(
        actionTitle: String,
        result: ScriptPluginResult
    ) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let headline = result.succeeded
            ? String(localized: "“\(actionTitle)”执行成功。")
            : String(localized: "“\(actionTitle)”执行失败（退出码 \(result.exitCode)）。")

        var streams: [(label: String, value: String)] = []
        if result.succeeded {
            if !stdout.isEmpty {
                streams.append((String(localized: "标准输出"), stdout))
            }
            if !stderr.isEmpty {
                streams.append((String(localized: "标准错误"), stderr))
            }
        } else {
            // 失败时同时保留 stderr 和 stdout：很多 CLI 会把有用的诊断与上下文分写到两路。
            if !stderr.isEmpty {
                streams.append((String(localized: "标准错误"), stderr))
            }
            if !stdout.isEmpty {
                streams.append((String(localized: "标准输出"), stdout))
            }
        }

        guard !streams.isEmpty else { return headline }
        return "\(headline)\n\(boundedDetails(streams))"
    }

    /// Unified Log 只记录不可逆推出正文的元数据。插件输出仍可在当前结果弹窗中
    /// 有界展示，但绝不能进入长期系统日志（其中可能包含 token 或项目内容）。
    static func auditSummary(actionId: String, result: ScriptPluginResult) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: "._-"))
        let safeActionId = actionId.unicodeScalars.map { scalar -> Character in
            return allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        return "[plugin] action=\(String(safeActionId.prefix(128))) "
            + "exit=\(result.exitCode) "
            + "stdoutBytes=\(result.stdout.utf8.count) "
            + "stderrBytes=\(result.stderr.utf8.count)"
    }

    /// 将各输出流公平分配到同一个 UI 预算中，确保任何一路都不会被另一路完全挤掉。
    private static func boundedDetails(_ streams: [(label: String, value: String)]) -> String {
        let separator = "\n\n"
        let overhead = streams.reduce(0) { $0 + $1.label.count + 2 }
            + separator.count * max(0, streams.count - 1)
        let available = max(0, detailLimit - overhead)
        let quota = available / streams.count
        var remainder = available % streams.count

        return streams.map { stream in
            let streamLimit = quota + (remainder > 0 ? 1 : 0)
            remainder = max(0, remainder - 1)
            return "\(stream.label)：\n\(truncated(stream.value, limit: streamLimit))"
        }
        .joined(separator: separator)
    }

    private static func truncated(_ value: String, limit: Int) -> String {
        guard value.count > limit else { return value }
        guard limit > 0 else { return "" }
        guard limit > 1 else { return "…" }
        return String(value.prefix(limit - 1)) + "…"
    }
}
