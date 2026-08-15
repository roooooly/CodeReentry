import SwiftUI
import SwiftData
import Observation
import AppKit
import DevHubCore

struct GlobalSessionProject: Identifiable, Equatable {
    let id: UUID
    let stableId: String
    let name: String
    let path: String
}

/// Immutable projection used by the global list. Fetching managed
/// `SessionIndex` objects into the app's main context caused the context to
/// retain the entire result set after leaving the page. A short-lived read
/// context now produces these compact values and can be released immediately.
struct GlobalSessionItem: Identifiable, Equatable {
    let id: UUID
    let identityKey: String
    let tool: String
    let toolSessionId: String
    let sourcePath: String
    let projectCwd: String
    let startedAt: Date
    let updatedAt: Date
    let messageCount: Int
    let title: String?
    let preview: String
    let projectId: UUID?

    init(session: SessionIndex) {
        id = session.id
        identityKey = session.identityKey
        tool = session.tool
        toolSessionId = session.toolSessionId
        sourcePath = session.sourcePath
        projectCwd = session.projectCwd
        startedAt = session.startedAt
        updatedAt = session.updatedAt
        messageCount = session.messageCount
        title = session.title
        preview = session.preview
        projectId = session.project?.id
    }

    var detailMetadata: SessionDetailMetadata {
        SessionDetailMetadata(
            tool: tool,
            toolSessionId: toolSessionId,
            startedAt: startedAt,
            messageCount: messageCount,
            title: title,
            preview: preview
        )
    }

    var hasReadableConversation: Bool {
        SessionDisplayText.hasReadableConversation(
            messageCount: messageCount,
            title: title,
            preview: preview
        )
    }
}

enum GlobalSessionScope: Hashable {
    case all
    case unclassified
    case project(UUID)
}

@MainActor
@Observable
final class AllSessionsViewModel {
    static let pageSize = 25

    private(set) var allSessions: [GlobalSessionItem] = []
    private(set) var projects: [GlobalSessionProject] = []
    private(set) var visibleLimit = pageSize
    var searchText = "" {
        didSet {
            if oldValue != searchText { resetVisibleLimit() }
        }
    }
    var toolFilter = "" {
        didSet {
            if oldValue != toolFilter { resetVisibleLimit() }
        }
    }
    var scope: GlobalSessionScope = .all {
        didSet {
            if oldValue != scope { resetVisibleLimit() }
        }
    }

    func load(from container: ModelContainer) {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let rows = (try? context.fetch(FetchDescriptor<SessionIndex>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        ))) ?? []
        allSessions = rows.map(GlobalSessionItem.init)
        projects = ((try? context.fetch(FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\.name)]
        ))) ?? []).map {
            GlobalSessionProject(id: $0.id, stableId: $0.stableId, name: $0.name, path: $0.path)
        }
        resetVisibleLimit()
    }

    var filteredSessions: [GlobalSessionItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allSessions.filter { session in
            guard toolFilter.isEmpty || session.tool == toolFilter else { return false }
            switch scope {
            case .all:
                break
            case .unclassified:
                guard session.projectId == nil else { return false }
            case .project(let id):
                guard session.projectId == id else { return false }
            }
            guard matches(session, normalizedQuery: query) || query.isEmpty else {
                // 全局视图额外允许按项目名称/路径过滤，仍只读已缓存元数据。
                guard let project = project(for: session) else { return false }
                return project.name.lowercased().contains(query)
                    || project.path.lowercased().contains(query)
            }
            return true
        }
    }

    var availableTools: [String] {
        Array(Set(allSessions.map(\.tool))).sorted()
    }

    var unclassifiedCount: Int {
        allSessions.lazy.filter { $0.projectId == nil }.count
    }

    func loadMore(upTo totalCount: Int) {
        visibleLimit = min(totalCount, visibleLimit + Self.pageSize)
    }

    func project(for session: GlobalSessionItem) -> GlobalSessionProject? {
        guard let id = session.projectId else { return nil }
        return projects.first { $0.id == id }
    }

    func assign(
        _ session: GlobalSessionItem,
        to project: GlobalSessionProject,
        in container: ModelContainer
    ) async throws {
        let writer = SessionIndexWriter(modelContainer: container)
        let assigned = try await writer.assignProject(
            identityKey: session.identityKey,
            projectStableId: project.stableId
        )
        guard assigned else { throw GlobalSessionError.assignmentTargetMissing }
        load(from: container)
    }

    private func matches(_ session: GlobalSessionItem, normalizedQuery query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return (session.title?.lowercased().contains(query) ?? false)
            || session.preview.lowercased().contains(query)
            || session.tool.lowercased().contains(query)
            || session.toolSessionId.lowercased().contains(query)
    }

    private func resetVisibleLimit() {
        visibleLimit = Self.pageSize
    }
}

struct AllSessionsView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel = AllSessionsViewModel()
    @State private var isRefreshing = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var detailSession: GlobalSessionItem?

    var body: some View {
        let filteredSessions = viewModel.filteredSessions
        ZStack {
            DevHubPaperBackground()
            VStack(spacing: 0) {
                header
                if viewModel.allSessions.isEmpty {
                    ContentUnavailableView(
                        String(localized: "尚无会话索引"),
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(String(localized: "点击刷新以扫描 Claude Code、Codex、ZCode 与可用的 Kimi 本地元数据。"))
                    )
                } else if filteredSessions.isEmpty {
                    ContentUnavailableView.search(text: viewModel.searchText)
                } else {
                    sessionList(filteredSessions)
                }
            }
        }
        .navigationTitle(String(localized: "全部会话"))
        .task { viewModel.load(from: deps.modelContainer) }
        .onReceive(NotificationCenter.default.publisher(for: SidebarViewModel.projectsChangedNotification)) { _ in
            viewModel.load(from: deps.modelContainer)
        }
        .alert(
            String(localized: "会话操作失败"),
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button(String(localized: "好")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $detailSession) { session in
            SessionDetailView(
                viewModel: SessionDetailViewModel(
                    session: session.detailMetadata,
                    reader: deps.sessionReader(forToolId: session.tool)
                ),
                onOpenOriginal: { Task { await open(session); detailSession = nil } }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                DevHubSectionHeading(
                    eyebrow: String(localized: "DEVHUB / SESSIONS"),
                    title: String(localized: "会话是项目的工作记录"),
                    subtitle: String(localized: "只读聚合本机会话；未分类的 ZCode 会话可手动归到已注册项目。")
                )
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    DevHubPill(
                        text: statusMessage ?? String(localized: "\(viewModel.allSessions.count) 个本地会话"),
                        color: isRefreshing ? DevHubTheme.gold : DevHubTheme.teal
                    )
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(String(localized: "刷新索引"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isRefreshing)
                }
            }

            DevHubCard(padding: 12) {
                HStack {
                    Image(systemName: "line.3.horizontal.decrease")
                        .foregroundStyle(DevHubTheme.accent)
                    TextField(
                        String(localized: "搜索标题、摘要、工具或会话 ID"),
                        text: $viewModel.searchText
                    )
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(String(localized: "全局会话搜索框"))

                    Picker(String(localized: "工具"), selection: $viewModel.toolFilter) {
                        Text(String(localized: "全部工具")).tag("")
                        ForEach(viewModel.availableTools, id: \.self) { tool in
                            Text(tool).tag(tool)
                        }
                    }
                    .frame(width: 170)

                    Picker(String(localized: "项目"), selection: $viewModel.scope) {
                        Text(String(localized: "全部项目")).tag(GlobalSessionScope.all)
                        Text(String(localized: "未分类（\(viewModel.unclassifiedCount)）"))
                            .tag(GlobalSessionScope.unclassified)
                        ForEach(viewModel.projects) { project in
                            Text(project.name).tag(GlobalSessionScope.project(project.id))
                        }
                    }
                    .frame(width: 210)
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .frame(maxWidth: 1180)
    }

    private func sessionList(_ filteredSessions: [GlobalSessionItem]) -> some View {
        let visibleSessions = Array(filteredSessions.prefix(viewModel.visibleLimit))
        let remainingCount = max(0, filteredSessions.count - visibleSessions.count)
        let nextPageCount = min(AllSessionsViewModel.pageSize, remainingCount)

        return List {
            ForEach(visibleSessions) { session in
                GlobalSessionRow(
                    session: session,
                    project: viewModel.project(for: session),
                    projects: viewModel.projects,
                    isSelected: deps.selectedSessionId == session.toolSessionId,
                    onSelect: { deps.selectedSessionId = session.toolSessionId },
                    onViewConversation: { detailSession = session },
                    onAssign: { project in Task { await assign(session, to: project) } },
                    onOpen: { Task { await open(session) } },
                    onReveal: { reveal(session) }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 5, leading: 10, bottom: 5, trailing: 10))
            }

            if remainingCount > 0 {
                Button {
                    viewModel.loadMore(upTo: filteredSessions.count)
                } label: {
                    VStack(spacing: 4) {
                        Label(
                            String(localized: "再显示 \(nextPageCount) 个"),
                            systemImage: "arrow.down.circle"
                        )
                        .font(.callout.weight(.semibold))
                        Text(String(localized: "已显示 \(visibleSessions.count) / \(filteredSessions.count) 个会话"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .accessibilityHint(String(localized: "按需载入下一批会话，不读取会话正文"))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 1180)
    }

    @MainActor
    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusMessage = String(localized: "正在扫描…")
        do {
            try await deps.runAggregation()
            viewModel.load(from: deps.modelContainer)
            statusMessage = String(localized: "已更新 \(viewModel.allSessions.count) 个会话")
        } catch {
            viewModel.load(from: deps.modelContainer)
            errorMessage = error.localizedDescription
            statusMessage = nil
        }
        isRefreshing = false
    }

    @MainActor
    private func assign(_ session: GlobalSessionItem, to project: GlobalSessionProject) async {
        do {
            try await viewModel.assign(session, to: project, in: deps.modelContainer)
            statusMessage = String(localized: "已将会话归类到“\(project.name)”")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func open(_ session: GlobalSessionItem) async {
        do {
            guard let adapter = deps.adapter(for: session.tool) else {
                throw GlobalSessionError.adapterUnavailable(session.tool)
            }
            let cwd = session.projectCwd.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.path
                : session.projectCwd
            let context = LaunchContext(
                projectPath: cwd,
                renderedMemoryFile: nil,
                sessionId: session.toolSessionId,
                tool: nil
            )
            let instance: ToolInstance
            if session.tool == "kimi" {
                // Kimi 只支持打开 GUI，不声称恢复到指定元数据记录。
                instance = try await adapter.launchNew(ctx: context)
            } else {
                instance = try await adapter.resume(sessionId: session.toolSessionId, ctx: context)
            }
            switch instance {
            case .cli(let launcherPath):
                _ = try await deps.terminalController.execute(terminal: .terminal, launcherPath: launcherPath)
            case .gui(let bundleId):
                try await deps.guiLauncher.launchApp(bundleId: bundleId, projectPath: nil)
            }
            statusMessage = session.tool == "kimi"
                ? String(localized: "已打开 Kimi（未恢复指定会话）")
                : String(localized: "已在原工具中打开")
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reveal(_ session: GlobalSessionItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.sourcePath)])
    }
}

private struct GlobalSessionRow: View {
    let session: GlobalSessionItem
    let project: GlobalSessionProject?
    let projects: [GlobalSessionProject]
    let isSelected: Bool
    let onSelect: () -> Void
    let onViewConversation: () -> Void
    let onAssign: (GlobalSessionProject) -> Void
    let onOpen: () -> Void
    let onReveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(displayTitle)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(DevHubTheme.ink)
                    .lineLimit(1)
                Text(session.tool)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(DevHubTheme.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(DevHubTheme.accent.opacity(0.09), in: Capsule())
                if let project {
                    Label(project.name, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label(String(localized: "未分类"), systemImage: "questionmark.folder")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text(session.startedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(displayPreview)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if session.tool == "kimi" {
                Label(
                    String(localized: "仅索引本地状态元数据；不读取消息内容，也不能恢复指定会话。"),
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
            if session.tool != "kimi" && !session.hasReadableConversation {
                Label(String(localized: "内容格式暂时无法解析；请用“显示源文件”检查原始记录。"),
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Text(session.toolSessionId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
                if session.tool != "kimi" && session.hasReadableConversation {
                    Button(action: onViewConversation) {
                        Label(String(localized: "查看对话"), systemImage: "doc.text")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(DevHubTheme.accent)
                    .accessibilityHint(String(localized: "在 DevHub 内查看完整对话正文"))
                }
                Button(String(localized: "显示源文件"), action: onReveal)
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                if session.tool == "zcode" {
                    Menu {
                        if projects.isEmpty {
                            Text(String(localized: "请先注册项目"))
                        } else {
                            ForEach(projects) { project in
                                Button(project.name) { onAssign(project) }
                            }
                        }
                    } label: {
                        Label(
                            project == nil ? String(localized: "归类到项目") : String(localized: "更改归类"),
                            systemImage: "folder.badge.plus"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(projects.isEmpty)
                }

                Button(action: onOpen) {
                    Label(
                        session.tool == "kimi" ? String(localized: "打开 Kimi") : String(localized: "在原工具中继续"),
                        systemImage: session.tool == "kimi" ? "arrow.up.forward.app" : "arrow.uturn.forward"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(session.tool != "kimi" && session.projectCwd.isEmpty)
            }
        }
        .padding(12)
        .devHubSurface()
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isSelected ? DevHubTheme.accent.opacity(0.48) : .clear, lineWidth: 1.5)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityValue(isSelected ? String(localized: "已选中") : String(localized: "未选中"))
        .accessibilityHint(String(localized: "选中后可用于会话范围的插件操作"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, onSelect)
        .accessibilityAction(named: Text(String(localized: "选中此会话")), onSelect)
    }

    private var displayTitle: String {
        SessionDisplayText.displayTitle(title: session.title, preview: session.preview)
            ?? String(localized: "未命名会话")
    }

    private var displayPreview: String {
        SessionDisplayText.displayPreview(session.preview)
            ?? String(localized: "刷新后可读取实际用户请求")
    }
}

enum GlobalSessionError: LocalizedError {
    case assignmentTargetMissing
    case adapterUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .assignmentTargetMissing:
            return String(localized: "会话或目标项目已不存在，请刷新后重试。")
        case .adapterUnavailable(let tool):
            return String(localized: "工具 \(tool) 的启动适配器不可用。")
        }
    }
}
