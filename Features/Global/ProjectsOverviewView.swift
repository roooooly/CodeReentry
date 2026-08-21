import SwiftUI
import SwiftData
import DevHubCore

@Observable
@MainActor
final class ProjectsOverviewViewModel {
    /// 搜索关键字（空表示不过滤）。
    var searchText: String = ""
    /// 状态过滤；nil 表示全部。
    var statusFilter: ProjectStatus? = nil
    /// 仅显示路径可用的项目。
    var hideMissingPaths: Bool = false

    /// 当前卡片数据快照。
    private(set) var cards: [ProjectCardData] = []
    /// 状态分布统计（供仪表盘条）。
    private(set) var statusDistribution: [ProjectStatus: Int] = [:]
    /// 本月订阅总成本（按币种，跨所有项目+全局）。
    private(set) var monthlyCostByCurrency: [String: Decimal] = [:]
    /// 首页会话扫描状态。扫描仍只由用户显式触发。
    private(set) var isScanningSessions = false
    private(set) var sessionScanStatus: String?

    var activeProjectCount: Int { statusDistribution[.active] ?? 0 }
    var attentionProjectCount: Int { cards.filter { !$0.pathAvailable }.count }
    var projectSessionCount: Int { cards.reduce(0) { $0 + $1.sessionCount } }

    /// 从短生命周期读取上下文重新加载。
    ///
    /// 首页需要会话/工具/订阅关系来生成卡片，但不应把这些托管对象全部
    /// 注册到应用的主上下文并长期驻留。这里只投影为纯值数据，函数返回后
    /// 读取上下文及其关系图即可释放。
    func load(from container: ModelContainer) {
        let ctx = ModelContext(container)
        ctx.autosaveEnabled = false
        let descriptor = FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\.name, order: .forward)]
        )
        guard let projects = try? ctx.fetch(descriptor) else { return }

        cards = projects.map { Self.cardData(for: $0) }

        // 状态分布
        var dist: [ProjectStatus: Int] = [:]
        for c in cards { dist[c.status, default: 0] += 1 }
        statusDistribution = dist

        // 跨项目订阅月费合计（含全局无项目订阅）
        let allSubs = (try? ctx.fetch(FetchDescriptor<Subscription>())) ?? []
        let snapshots = allSubs.filter(\.active).map(SubscriptionSnapshot.init)
        monthlyCostByCurrency = SubscriptionCalculator.monthlyTotalsByCurrency(snapshots)
    }

    /// 从项目总览触发一次全局会话增量扫描。调用方注入真实聚合操作，测试可用
    /// 合成闭包验证首次价值路径，不需要读取开发机上的任何会话。
    func scanSessions(
        from container: ModelContainer,
        operation: @MainActor () async throws -> Void
    ) async throws {
        guard !isScanningSessions else { return }
        isScanningSessions = true
        sessionScanStatus = String(localized: "正在扫描本地会话…")
        defer { isScanningSessions = false }

        do {
            try await operation()
            load(from: container)
            sessionScanStatus = String(localized: "已索引 \(projectSessionCount) 个项目会话")
        } catch {
            // SessionAggregator 会保留其他成功 reader 的结果；即使部分失败也必须
            // 立即刷新卡片，再把明确错误交给界面展示。
            load(from: container)
            sessionScanStatus = String(localized: "部分会话来源已更新")
            throw error
        }
    }

    /// 过滤+搜索+排序后的卡片（搜索用 FuzzyMatcher）。
    var visibleCards: [ProjectCardData] {
        var result = cards
        if hideMissingPaths {
            result = result.filter(\.pathAvailable)
        }
        if let s = statusFilter {
            result = result.filter { $0.status == s }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            let ranked = FuzzyMatcher.rank(query: query, in: result) { $0.name }
            result = ranked.map(\.item)
        }
        return result
    }

    /// 把 SwiftData Project 投影为纯值类型卡片数据。独立函数，便于单元测试。
    static func cardData(for project: Project) -> ProjectCardData {
        let pathOK = ProjectPathAvailability.evaluate(path: project.path) == .available
        let activeSubs = project.subscriptions.filter(\.active).map(SubscriptionSnapshot.init)
        let monthly = SubscriptionCalculator.monthlyTotalsByCurrency(activeSubs)
        let lastActivity = project.sessions.map(\.updatedAt).max()
        let latestSession = project.sessions
            .filter {
                $0.tool != "kimi"
                    && (SessionDisplayText.hasReadableConversation(
                            messageCount: $0.messageCount,
                            title: $0.title,
                            preview: $0.preview
                        )
                        || ($0.tool == "opencode"
                            && SessionDisplayText.displayTitle(
                                title: $0.title,
                                preview: $0.preview
                            ) != nil))
            }
            .max { $0.updatedAt < $1.updatedAt }
            .map { session in
                ProjectCardData.ResumeTarget(
                    tool: session.tool,
                    sessionId: session.toolSessionId,
                    cwd: session.projectCwd.isEmpty ? project.path : session.projectCwd,
                    title: SessionDisplayText.displayTitle(
                        title: session.title,
                        preview: session.preview
                    ) ?? String(localized: "最近会话")
                )
            }
        return ProjectCardData(
            id: project.id,
            stableId: project.stableId,
            name: project.name,
            icon: project.icon,
            colorHex: project.color,
            status: project.statusEnum,
            version: project.versionString,
            pathAvailable: pathOK,
            toolCount: project.tools.filter(\.enabled).count,
            sessionCount: project.sessions.count,
            monthlyCostByCurrency: monthly,
            lastActivityAt: lastActivity,
            latestSession: latestSession
        )
    }
}

/// 项目总览卡片网格页（§项目总览）。
/// 提供卡片网格 + 仪表盘统计条 + 搜索/状态过滤。
struct ProjectsOverviewView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel = ProjectsOverviewViewModel()
    /// 正在编辑状态/版本的项目 stableId（非 nil 时弹出编辑器 sheet）。
    @State private var editingStableId: String?
    @State private var launchError: String?
    @State private var sessionScanError: String?

    private let columns = [GridItem(.adaptive(minimum: 330, maximum: 520), spacing: 16)]

    var body: some View {
        ZStack {
            DevHubPaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pageHeading
                    dashboardStrip
                    toolbar
                    if viewModel.visibleCards.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(viewModel.visibleCards) { card in
                                ProjectCardView(
                                    data: card,
                                    onTap: { open(card) },
                                    onChangeStatus: { editingStableId = card.stableId },
                                    onContinueLatest: card.latestSession == nil ? nil : {
                                        Task { await continueLatest(in: card) }
                                    }
                                )
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
                .padding(26)
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .navigationTitle(String(localized: "项目总览"))
        .task { reload() }
        .onReceive(NotificationCenter.default.publisher(for: SidebarViewModel.projectsChangedNotification)) { _ in
            reload()
        }
        .sheet(isPresented: Binding(
            get: { editingStableId != nil },
            set: { if !$0 { editingStableId = nil } }
        )) {
            if let project = editingProject {
                ProjectStatusVersionEditor(project: project) {
                    NotificationCenter.default.post(name: SidebarViewModel.projectsChangedNotification, object: nil)
                }
            }
        }
        .alert(
            String(localized: "无法继续会话"),
            isPresented: Binding(
                get: { launchError != nil },
                set: { if !$0 { launchError = nil } }
            )
        ) {
            Button(String(localized: "好")) { launchError = nil }
        } message: {
            Text(launchError ?? "")
        }
        .alert(
            String(localized: "会话索引未完全更新"),
            isPresented: Binding(
                get: { sessionScanError != nil },
                set: { if !$0 { sessionScanError = nil } }
            )
        ) {
            Button(String(localized: "好")) { sessionScanError = nil }
        } message: {
            Text(sessionScanError ?? "")
        }
    }

    /// 由 editingStableId 查询出的待编辑项目（nil 时 sheet 关闭）。
    private var editingProject: Project? {
        guard let stableId = editingStableId else { return nil }
        let pred = #Predicate<Project> { $0.stableId == stableId }
        return (try? modelContext.fetch(FetchDescriptor<Project>(predicate: pred)))?.first
    }

    private var pageHeading: some View {
        HStack(alignment: .top, spacing: 20) {
            DevHubSectionHeading(
                eyebrow: String(localized: "CODEREENTRY / WORKSPACE"),
                title: String(localized: "从项目继续，而不是从工具重新开始"),
                subtitle: String(localized: "项目是工作上下文；工具、会话、记忆和固定成本都围绕它组织。")
            )
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 9) {
                DevHubPill(
                    text: String(localized: "本地索引 · 按需读取"),
                    color: viewModel.isScanningSessions ? DevHubTheme.gold : DevHubTheme.teal
                )
                HStack(spacing: 8) {
                    Button {
                        Task { await scanLocalSessions() }
                    } label: {
                        HStack(spacing: 6) {
                            if viewModel.isScanningSessions {
                                ProgressView().controlSize(.small)
                            }
                            Label(
                                viewModel.isScanningSessions
                                    ? String(localized: "正在扫描…")
                                    : String(localized: "扫描本地会话"),
                                systemImage: "tray.and.arrow.down"
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.isScanningSessions || viewModel.cards.isEmpty)
                    .accessibilityHint(
                        String(localized: "仅在点击后增量读取本机会话元数据，不在后台扫描")
                    )
                    Button {
                        NotificationCenter.default.post(
                            name: Notification.Name("DevHubShowCommandPalette"),
                            object: nil
                        )
                    } label: {
                        Label(String(localized: "命令面板"), systemImage: "command")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("p", modifiers: .command)
                }
                if let status = viewModel.sessionScanStatus {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var dashboardStrip: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
            spacing: 12
        ) {
            DevHubMetricCard(
                value: "\(viewModel.cards.count)",
                label: String(localized: "全部项目"),
                detail: String(localized: "已登记工作区"),
                systemImage: "folder.fill",
                accent: DevHubTheme.accent
            )
            DevHubMetricCard(
                value: "\(viewModel.activeProjectCount)",
                label: String(localized: "正在进行"),
                detail: String(localized: "可直接继续"),
                systemImage: "bolt.fill",
                accent: DevHubTheme.blue
            )
            DevHubMetricCard(
                value: "\(viewModel.attentionProjectCount)",
                label: String(localized: "需要处理"),
                detail: String(localized: "失效项目路径"),
                systemImage: "exclamationmark.triangle.fill",
                accent: viewModel.attentionProjectCount == 0 ? DevHubTheme.green : .orange
            )
            DevHubMetricCard(
                value: monthlyCostValue,
                label: String(localized: "订阅月费"),
                detail: String(localized: "固定成本"),
                systemImage: "creditcard.fill",
                accent: DevHubTheme.gold
            )
        }
    }

    private var monthlyCostValue: String {
        guard !viewModel.monthlyCostByCurrency.isEmpty else { return "—" }
        if viewModel.monthlyCostByCurrency.count == 1,
           let (currency, amount) = viewModel.monthlyCostByCurrency.first {
            return ProjectCardView.formatAmount(amount: amount, currency: currency)
        }
        return "\(viewModel.monthlyCostByCurrency.count) " + String(localized: "种币种")
    }

    private var toolbar: some View {
        DevHubCard(padding: 12) {
            HStack(spacing: 12) {
                Label(String(localized: "筛选"), systemImage: "line.3.horizontal.decrease")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DevHubTheme.secondaryInk)
                TextField(String(localized: "搜索项目…"), text: $viewModel.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Picker(String(localized: "状态"), selection: $viewModel.statusFilter) {
                    Text(String(localized: "全部状态")).tag(ProjectStatus?.none)
                    ForEach(ProjectStatus.allCases, id: \.self) { status in
                        Text(status.title).tag(ProjectStatus?.some(status))
                    }
                }
                .frame(width: 160)
                .accessibilityLabel(String(localized: "按状态过滤"))
                Toggle(String(localized: "仅可用"), isOn: $viewModel.hideMissingPaths)
                    .toggleStyle(.checkbox)
                    .accessibilityHint(String(localized: "隐藏路径已失效的项目"))
                Spacer()
                Text(String(localized: "显示 \(viewModel.visibleCards.count) 个"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    reload()
                } label: {
                    Label(String(localized: "刷新"), systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if viewModel.searchText.isEmpty && viewModel.statusFilter == nil {
            ContentUnavailableView(
                String(localized: "还没有项目"),
                systemImage: "square.grid.2x2",
                description: Text(String(localized: "在侧边栏点「添加项目」或拖入文件夹来注册。"))
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            ContentUnavailableView.search(text: viewModel.searchText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        }
    }

    private func open(_ card: ProjectCardData) {
        deps.selectedGlobalDestination = nil
        deps.selectedProjectStableId = card.stableId
    }

    @MainActor
    private func continueLatest(in card: ProjectCardData) async {
        guard let session = card.latestSession else { return }
        guard let adapter = deps.adapter(for: session.tool) else {
            launchError = String(localized: "未找到 \(session.tool) 的启动适配器。")
            return
        }
        do {
            let context = LaunchContext(
                projectPath: session.cwd,
                renderedMemoryFile: nil,
                sessionId: session.sessionId,
                tool: nil
            )
            let instance = try await adapter.resume(sessionId: session.sessionId, ctx: context)
            switch instance {
            case .cli(let launcherPath):
                _ = try await deps.terminalController.execute(
                    terminal: .terminal,
                    launcherPath: launcherPath
                )
            case .gui(let bundleId):
                try await deps.guiLauncher.launchApp(bundleId: bundleId, projectPath: session.cwd)
            }
        } catch {
            launchError = error.localizedDescription
        }
    }

    @MainActor
    private func scanLocalSessions() async {
        do {
            try await viewModel.scanSessions(from: deps.modelContainer) {
                try await deps.runAggregation()
            }
        } catch {
            sessionScanError = error.localizedDescription
        }
    }

    private func reload() {
        viewModel.load(from: deps.modelContainer)
    }
}
