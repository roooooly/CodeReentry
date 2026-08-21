import SwiftUI
import SwiftData
import AppKit
import DevHubCore

enum ProjectPathAvailability: Equatable {
    case checking
    case available
    case missing

    static func evaluate(
        path: String,
        fileManager: FileManager = .default
    ) -> ProjectPathAvailability {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .missing
        }
        return .available
    }
}

func projectRelocationErrorMessage(_ error: Error) -> String {
    guard let registryError = error as? ProjectRegistryError else {
        return error.localizedDescription
    }
    switch registryError {
    case .duplicatePath:
        return String(localized: "所选文件夹已被另一个项目注册。")
    case .duplicateStableId:
        return String(localized: "所选文件夹已绑定到另一个有效项目。")
    case .notFound:
        return String(localized: "项目记录已不存在，请刷新后重试。")
    case .invalidPath:
        return String(localized: "请选择一个仍然存在的项目文件夹。")
    case .stableIdMismatch:
        return String(localized: "所选文件夹属于另一个 CodeReentry 项目，请选择移动后的原项目目录。")
    }
}

struct ProjectDetailView: View {
    let projectStableId: String
    @Environment(AppDependencies.self) private var deps
    @Environment(\.modelContext) private var modelContext
    @State private var router = ProjectRouter()
    @State private var gitStatus: GitStatus?
    @State private var project: Project?
    @State private var pathAvailability: ProjectPathAvailability = .checking
    @State private var relocationError: String?
    @State private var showingStatusVersionEditor = false

    var body: some View {
        Group {
            if let project {
                content(for: project)
            } else {
                Text(String(localized: "项目不存在或路径已失效"))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: projectStableId) {
            // 会话选择属于项目作用域；切换项目后不能把旧会话传给新项目的插件。
            deps.selectedSessionId = nil
            await reloadProject()
        }
        // 命令面板"切 tab"通知（DevHubSwitchTab）→ 更新 router
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DevHubSwitchTab"))) { note in
            if let tab = note.object as? DetailTab {
                router.select(tab, enabledTabs: deps.enabledDetailTabs)
            }
        }
        .onAppear {
            router.reconcile(enabledTabs: deps.enabledDetailTabs)
        }
        .onChange(of: deps.enabledDetailTabs) { _, enabledTabs in
            router.reconcile(enabledTabs: enabledTabs)
        }
        .onReceive(NotificationCenter.default.publisher(for: SidebarViewModel.projectsChangedNotification)) { _ in
            Task { await reloadProject() }
        }
        .alert(
            String(localized: "无法重新定位项目"),
            isPresented: Binding(
                get: { relocationError != nil },
                set: { if !$0 { relocationError = nil } }
            )
        ) {
            Button(String(localized: "好")) { relocationError = nil }
        } message: {
            Text(relocationError ?? "")
        }
        .sheet(isPresented: $showingStatusVersionEditor) {
            if let project {
                ProjectStatusVersionEditor(project: project) {
                    NotificationCenter.default.post(name: SidebarViewModel.projectsChangedNotification, object: nil)
                }
            }
        }
    }

    @ViewBuilder
    private func content(for project: Project) -> some View {
        ZStack {
            DevHubPaperBackground()
            VStack(spacing: 0) {
                ProjectDetailHeader(
                    project: project,
                    gitStatus: gitStatus,
                    pathAvailability: pathAvailability,
                    onEditStatusVersion: { showingStatusVersionEditor = true }
                )
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)
                switch pathAvailability {
                case .checking:
                    ProgressView(String(localized: "正在检查项目路径…"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .missing:
                    missingPathView(for: project)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .available:
                    tabButtons
                        .padding(.horizontal, 20)
                        .padding(.bottom, 10)
                    currentTabView(for: project, selectedTab: activeTab)
                        // 子 tab 普遍持有 @State ViewModel。项目变化时强制重建整个
                        // 项目作用域子树，避免旧项目的数据/异步任务被复用于新项目。
                        .id(project.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle(project.name)
    }

    private func missingPathView(for project: Project) -> some View {
        ContentUnavailableView {
            Label(String(localized: "项目路径已失效"), systemImage: "exclamationmark.triangle.fill")
        } description: {
            VStack(spacing: 6) {
                Text(String(localized: "项目可能已被移动或删除。重新选择目录后，CodeReentry 会保留现有会话、订阅和平台绑定。"))
                Text(project.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        } actions: {
            if !deps.isDemoMode {
                Button(String(localized: "重新定位…")) {
                    chooseRelocationFolder(for: project)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var tabButtons: some View {
        DevHubCard(padding: 4) {
            HStack(spacing: 3) {
                ForEach(deps.enabledDetailTabs) { tab in
                    Button {
                        router.select(tab, enabledTabs: deps.enabledDetailTabs)
                    } label: {
                        Label(tab.title, systemImage: tab.systemImage)
                            .font(.caption.weight(.semibold))
                            .padding(.vertical, 7)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity)
                            .background(
                                activeTab == tab ? DevHubTheme.accent.opacity(0.11) : .clear,
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(
                                activeTab == tab ? DevHubTheme.accent : DevHubTheme.secondaryInk
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tab.title)
                    .accessibilityValue(
                        activeTab == tab
                            ? String(localized: "已选中")
                            : String(localized: "未选中")
                    )
                    .accessibilityAddTraits(activeTab == tab ? .isSelected : [])
                }
            }
        }
    }

    private var activeTab: DetailTab {
        router.resolvedSelection(enabledTabs: deps.enabledDetailTabs)
    }

    @ViewBuilder
    private func currentTabView(for project: Project, selectedTab: DetailTab) -> some View {
        switch selectedTab {
        case .tools:
            ToolsTab(project: project)
        case .sessions:
            SessionsTab(project: project)
        case .memory:
            MemoryTab(project: project)
        case .subscriptions:
            SubscriptionsTab(project: project, store: deps.subscriptionStore, reminderScheduler: deps.reminderScheduler)
        case .platforms:
            PlatformsTab(project: project)
        case .ops:
            OpsTab(project: project)
        }
    }

    private func fetchProject() -> Project? {
        let target = projectStableId
        let descriptor = FetchDescriptor<Project>(
            predicate: #Predicate { $0.stableId == target }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private func reloadProject() async {
        guard let fetched = fetchProject() else {
            project = nil
            gitStatus = nil
            pathAvailability = .missing
            return
        }

        project = fetched
        let availability = ProjectPathAvailability.evaluate(path: fetched.path)
        pathAvailability = availability
        gitStatus = nil
        // Demo mode must remain self-contained: even Git status is skipped so
        // opening a synthetic project never starts an external process.
        guard availability == .available, !deps.isDemoMode else { return }
        gitStatus = try? await deps.gitStatusProvider.status(
            at: URL(fileURLWithPath: fetched.path, isDirectory: true)
        )
    }

    private func chooseRelocationFolder(for project: Project) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "重新定位“\(project.name)”")
        panel.message = String(localized: "请选择该项目移动后的文件夹。")
        panel.prompt = String(localized: "重新定位")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        let oldParent = URL(fileURLWithPath: project.path).deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: oldParent.path) {
            panel.directoryURL = oldParent
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        do {
            try deps.projectRegistry(in: modelContext).relocate(
                id: project.id,
                to: selectedURL.path(percentEncoded: false)
            )
            NotificationCenter.default.post(
                name: SidebarViewModel.projectsChangedNotification,
                object: nil
            )
            Task { await reloadProject() }
        } catch {
            relocationError = projectRelocationErrorMessage(error)
        }
    }
}

struct ProjectDetailHeader: View {
    let project: Project
    let gitStatus: GitStatus?
    let pathAvailability: ProjectPathAvailability
    var onEditStatusVersion: (() -> Void)? = nil

    var body: some View {
        DevHubCard(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "PROJECT / WORKSPACE"))
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(DevHubTheme.accent)
            HStack(spacing: 10) {
                Image(systemName: project.icon ?? "folder.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DevHubTheme.accent)
                    .frame(width: 40, height: 40)
                    .background(DevHubTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                Text(project.name)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(DevHubTheme.ink)
                    .lineLimit(1)
                StatusBadge(status: project.statusEnum)
                if !project.versionString.isEmpty {
                    DevHubPill(text: "v\(project.versionString)", color: DevHubTheme.gold)
                        .accessibilityLabel(String(localized: "版本 \(project.versionString)"))
                }
                if pathAvailability == .missing {
                    Label(String(localized: "路径失效"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.orange.opacity(0.12), in: Capsule())
                }
                Spacer()
                if !project.tags.isEmpty {
                    ForEach(project.tags.prefix(3), id: \.self) { tag in
                        DevHubPill(text: tag, color: DevHubTheme.secondaryInk)
                    }
                }
                if let onEditStatusVersion {
                    Button(action: onEditStatusVersion) {
                        Label(String(localized: "项目信息"), systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider().overlay(DevHubTheme.divider)

            if let status = gitStatus {
                HStack(spacing: 12) {
                    Label(status.branch, systemImage: "arrow.triangle.branch")
                        .font(.caption.weight(.medium))
                    Label(
                        status.dirtyFileCount > 0
                            ? String(localized: "\(status.dirtyFileCount) 个未提交改动")
                            : String(localized: "工作区干净"),
                        systemImage: status.dirtyFileCount > 0
                            ? "exclamationmark.circle.fill"
                            : "checkmark.circle.fill"
                    )
                    .foregroundStyle(status.dirtyFileCount > 0 ? .orange : DevHubTheme.green)
                    if !status.lastCommitSubject.isEmpty {
                        Label(status.lastCommitSubject, systemImage: "clock.arrow.circlepath")
                            .lineLimit(1)
                            .help(String(localized: "最近提交：\(status.lastCommitSubject)"))
                    }
                    Spacer()
                    Text(project.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(project.path)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if pathAvailability == .available {
                HStack {
                    Label(String(localized: "未检测到 Git 状态"), systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(project.path)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(headerAccessibility)
    }

    var headerAccessibility: String {
        var parts = [project.name]
        if pathAvailability == .missing {
            parts.append(String(localized: "项目路径已失效"))
        }
        if let s = gitStatus {
            parts.append(String(localized: "分支 \(s.branch)"))
            if !s.lastCommitSubject.isEmpty {
                parts.append(String(localized: "最近提交 \(s.lastCommitSubject)"))
            }
            if s.dirtyFileCount > 0 {
                parts.append(String(localized: "\(s.dirtyFileCount) 个未提交改动"))
            } else {
                parts.append(String(localized: "工作区干净"))
            }
        }
        return ListFormatter.localizedString(byJoining: parts)
    }
}
