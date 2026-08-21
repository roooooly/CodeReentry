import SwiftUI
import SwiftData
import AppKit
import DevHubCore

struct SessionsTab: View {
    let project: Project
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel = SessionsTabViewModel()
    @State private var isRefreshing = false
    @State private var launchFailure: TerminalLaunchFailure?
    @State private var statusMessage: String?
    @State private var detailSession: SessionIndex?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if viewModel.isEmpty {
                emptyState
            } else {
                sessionList
            }
        }
        .task {
            wireHandlers()
            // 先显示持久化索引。全盘 JSONL 刷新由用户显式触发，避免仅切换
            // 项目或启动应用就扫描庞大的历史会话目录。
            viewModel.load(project: project, from: deps.modelContainer.mainContext)
        }
        .terminalLaunchRecoveryAlert(
            failure: $launchFailure,
            fallbackTitle: String(localized: "会话操作失败")
        ) {
            statusMessage = String(localized: "一次性恢复命令已复制。请粘贴到 Terminal 后回车。")
        }
        .sheet(item: $detailSession) { session in
            SessionDetailView(
                viewModel: SessionDetailViewModel(
                    session: session,
                    reader: deps.sessionReader(forToolId: session.tool)
                ),
                onMeasureRecovery: { measureAndResume(session) },
                onOpenOriginal: { Task { await resume(session); detailSession = nil } }
            )
        }
    }

    private var toolbar: some View {
        HStack {
            TextField(String(localized: "搜索会话（标题/摘要）"), text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
                .accessibilityLabel(String(localized: "会话搜索框"))
            Spacer()
            Picker(String(localized: "工具过滤"), selection: $viewModel.toolFilter) {
                Text(String(localized: "全部工具")).tag("")
                ForEach(viewModel.availableTools, id: \.self) { tool in
                    Text(tool).tag(tool)
                }
            }
            .frame(width: 180)
            .accessibilityLabel(String(localized: "按工具过滤会话"))
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button {
                Task { await refreshSessions() }
            } label: {
                Label(String(localized: "刷新"), systemImage: "arrow.clockwise")
            }
            .disabled(isRefreshing)
        }
        .padding()
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(viewModel.toolGroups) { group in
                    Section(header: toolHeader(group.tool)) {
                        ForEach(group.sessions) { session in
                            SessionRow(
                                session: session,
                                isSelected: deps.selectedSessionId == session.toolSessionId,
                                onSelect: { deps.selectedSessionId = session.toolSessionId },
                                onViewConversation: { detailSession = session },
                                onResume: { Task { await resume(session) } },
                                onSummarize: { Task { await summarize(session) } }
                            )
                        }
                    }
                }
            }
            .padding()
        }
    }

    private func toolHeader(_ tool: String) -> some View {
        HStack {
            Circle()
                .fill(ToolColor.color(for: tool) == "orange" ? .orange :
                      ToolColor.color(for: tool) == "green"  ? .green  :
                      ToolColor.color(for: tool) == "blue"   ? .blue   :
                      ToolColor.color(for: tool) == "purple" ? .purple : .gray)
                .frame(width: 10, height: 10)
            Text(tool).font(.headline)
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(tool) 工具会话组"))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(String(localized: "尚无会话"))
                .font(.title3)
            Text(String(localized: "点击右上角“刷新”以增量扫描本机会话。"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// 注入生产实现：resume 走 adapter（同 ToolsTab 路径）；summary 走 reader.load → SummaryExtractor → MemoryStore。
    private func wireHandlers() {
        viewModel.resumeHandler = { session in
            let sessionPath = session.projectCwd.trimmingCharacters(in: .whitespacesAndNewlines)
            let cwd = ProjectPathAvailability.evaluate(path: sessionPath) == .available
                ? sessionPath
                : project.path
            try await deps.resumeSession(
                toolId: session.tool,
                sessionId: session.toolSessionId,
                projectPath: cwd,
                project: project
            )
        }
        viewModel.generateSummaryHandler = { session in
            // 完整路径：reader.load(detail) → SummaryExtractor.extractSummary(detail) → MemoryStore.write
            let toolId = session.tool
            let toolSessionId = session.toolSessionId
            guard let reader = deps.sessionReader(forToolId: toolId) else {
                throw SessionsSummaryError.readerUnavailable(toolId)
            }
            let detail = try await reader.load(toolSessionId)
            let summary = SummaryExtractor.extractSummary(from: detail)
            // 会话 cwd 可以是项目子目录，但项目记忆始终属于已注册的项目根目录。
            let store = deps.memoryStore(forProjectPath: SessionMemoryDestination.projectRoot(
                registeredProjectPath: project.path,
                sessionCwd: session.projectCwd
            ))
            try store.writeLastSessionSummary(
                summary,
                metadata: SessionSummaryMetadata(
                    tool: session.tool,
                    toolSessionId: session.toolSessionId,
                    sessionUpdatedAt: session.updatedAt
                )
            )
        }
    }

    @MainActor
    private func refreshSessions() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = String(localized: "正在扫描…")
        do {
            try await deps.runAggregation()
            viewModel.load(project: project, from: deps.modelContainer.mainContext)
            statusMessage = String(localized: "已更新 \(viewModel.allSessions.count) 个会话")
        } catch {
            viewModel.load(project: project, from: deps.modelContainer.mainContext)
            launchFailure = TerminalLaunchFailure(error)
            statusMessage = nil
        }
        isRefreshing = false
    }

    @MainActor
    private func resume(_ session: SessionIndex) async {
        do {
            try await viewModel.resumeInOriginalTool(session)
            statusMessage = String(localized: "已在原工具中打开")
        } catch {
            launchFailure = TerminalLaunchFailure(error)
        }
    }

    @MainActor
    private func measureAndResume(_ session: SessionIndex) {
        do {
            try deps.reentryTrials.start(
                projectStableID: project.stableId,
                toolIdentifier: session.tool,
                sessionStartedAt: session.startedAt
            )
            Task {
                do {
                    try await viewModel.resumeInOriginalTool(session)
                    statusMessage = String(localized: "已在原工具中打开")
                    detailSession = nil
                    deps.selectedGlobalDestination = .evidence
                } catch {
                    // Keep this view alive so the Terminal fallback alert stays
                    // actionable. The active timer can still be recorded as a
                    // launch failure or discarded from Recovery Evidence.
                    launchFailure = TerminalLaunchFailure(error)
                }
            }
        } catch {
            launchFailure = TerminalLaunchFailure(error)
        }
    }

    @MainActor
    private func summarize(_ session: SessionIndex) async {
        do {
            try await viewModel.generateSummary(for: session)
            statusMessage = String(localized: "会话总结已写入项目记忆")
        } catch {
            launchFailure = TerminalLaunchFailure(error)
        }
    }
}

enum SessionMemoryDestination {
    static func projectRoot(registeredProjectPath: String, sessionCwd: String) -> String {
        // 保留 sessionCwd 参数以明确区分 resume 的工作目录和 summary 的存储目录。
        _ = sessionCwd
        return registeredProjectPath
    }
}

enum SessionsSummaryError: Error, LocalizedError {
    case readerUnavailable(String)
    case adapterUnavailable(String)
    var errorDescription: String? {
        switch self {
        case .readerUnavailable(let tool): return String(localized: "工具 \(tool) 的 reader 不可用")
        case .adapterUnavailable(let tool): return String(localized: "工具 \(tool) 的 adapter 不可用")
        }
    }
}

struct SessionRow: View {
    let session: SessionIndex
    let isSelected: Bool
    let onSelect: () -> Void
    let onViewConversation: () -> Void
    let onResume: () -> Void
    let onSummarize: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(displayTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(session.startedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(displayPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if isMetadataOnly {
                Label(
                    session.tool == "kimi"
                        ? String(localized: "仅显示 Kimi 本地状态元数据；当前无法读取消息内容或恢复指定会话。")
                        : String(localized: "OpenCode 会话仅索引元数据；请在 OpenCode 中继续查看。"),
                    systemImage: "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if session.tool == "zcode" {
                Label(
                    String(localized: "\(ZcodeArtifactCounter.count(sourcePath: session.sourcePath, sessionId: session.toolSessionId)) 个 artifacts"),
                    systemImage: "shippingbox"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !isMetadataOnly && !hasReadableConversation {
                VStack(alignment: .leading, spacing: 3) {
                    Label(String(localized: "内容格式暂时无法解析，可直接检查原始文件。"),
                          systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(session.sourcePath)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Button(String(localized: "显示原始文件")) {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: session.sourcePath)
                        ])
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .font(.caption2)
            }
            HStack {
                Text(session.messageCount < 0 ? String(localized: "消息数未统计") : "\(session.messageCount) 条消息")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                if !isMetadataOnly && hasReadableConversation {
                    Button(action: onViewConversation) {
                        Label(String(localized: "查看对话"), systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(String(localized: "在 CodeReentry 内查看完整对话正文"))
                }
                Button(action: onResume) {
                    Label(
                        session.tool == "kimi" ? String(localized: "打开 Kimi") : String(localized: "在原工具中继续"),
                        systemImage: session.tool == "kimi" ? "arrow.up.forward.app" : "arrow.uturn.forward"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint(
                    session.tool == "kimi"
                        ? String(localized: "打开 Kimi 应用；不会恢复到此条元数据记录")
                        : String(localized: "用 \(session.tool) 打开此会话")
                )
                if !isMetadataOnly && hasReadableConversation {
                    Button(action: onSummarize) {
                        Label(String(localized: "生成本会话总结"), systemImage: "doc.text.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityHint(String(localized: "提取会话要点写入项目记忆"))
                }
            }
        }
        .padding()
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySessionLabel)
        .accessibilityValue(isSelected ? String(localized: "已选中") : String(localized: "未选中"))
        .accessibilityHint(String(localized: "选中后可用于会话范围的插件操作"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onSelect)
        .accessibilityAction(named: Text(String(localized: "选中此会话")), onSelect)
    }

    private var accessibilitySessionLabel: String {
        let messageCount = session.messageCount < 0
            ? String(localized: "消息数未统计")
            : String(localized: "\(session.messageCount) 条消息")
        return ListFormatter.localizedString(byJoining: [
            String(localized: "会话 \(displayTitle)"),
            messageCount
        ])
    }

    private var displayTitle: String {
        SessionDisplayText.displayTitle(title: session.title, preview: session.preview)
            ?? String(localized: "未命名会话")
    }

    private var displayPreview: String {
        SessionDisplayText.displayPreview(session.preview)
            ?? String(localized: "刷新后可读取实际用户请求")
    }

    private var hasReadableConversation: Bool {
        SessionDisplayText.hasReadableConversation(
            messageCount: session.messageCount,
            title: session.title,
            preview: session.preview
        )
    }

    private var isMetadataOnly: Bool {
        session.tool == "kimi" || session.tool == "opencode"
    }
}
