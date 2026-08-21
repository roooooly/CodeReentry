import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers
import OSLog
import DevHubCore

private let sidebarLogger = Logger(subsystem: "io.github.roooooly.devhub", category: "sidebar")

struct SidebarView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openSettings) private var openSettings
    @State private var viewModel = SidebarViewModel()

    var body: some View {
        List(selection: Binding(
            get: {
                deps.selectedGlobalDestination?.selectionTag
                    ?? deps.selectedProjectStableId
            },
            set: { selectDestination($0) }
        )) {
            // 顶部操作
            Section {
                Button {
                    viewModel.presentingAddDialog = true
                } label: {
                    Label(String(localized: "添加项目"), systemImage: "plus.circle")
                }
                .accessibilityLabel(String(localized: "添加项目"))
                .accessibilityHint(String(localized: "选择文件夹注册为新项目"))

                // 命令面板入口（⌘P 也可触发）
                Button {
                    NotificationCenter.default.post(name: Notification.Name("DevHubShowCommandPalette"), object: nil)
                } label: {
                    Label(String(localized: "⌘P 命令面板"), systemImage: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "打开命令面板"))
            }

            // 置顶
            if !viewModel.pinnedProjects.isEmpty {
                Section(String(localized: "置顶")) {
                    ForEach(viewModel.pinnedProjects) { project in
                        projectRow(project)
                    }
                }
            }

            // 活跃分组
            ForEach(viewModel.activeGroups) { group in
                Section(group.name) {
                    ForEach(group.projects) { project in
                        projectRow(project)
                    }
                }
            }

            // 归档
            if !viewModel.archivedProjects.isEmpty {
                Section(String(localized: "归档")) {
                    ForEach(viewModel.archivedProjects) { project in
                        projectRow(project)
                    }
                }
            }

            // 全局视图
            Section(String(localized: "全局")) {
                globalRow(.projects)
                globalRow(.usage)
                globalRow(.subscriptions)
                globalRow(.sessions)
                globalRow(.platforms)
                Button {
                    deps.requestedSettingsTab = .plugins
                    openSettings()
                } label: {
                    Label(String(localized: "插件"), systemImage: "puzzlepiece.extension")
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "打开插件设置"))
            }
        }
        .navigationTitle(String(localized: "CodeReentry"))
        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        .safeAreaInset(edge: .bottom) {
            sidebarFooter
        }
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: SidebarViewModel.projectsChangedNotification)) { _ in
            reload()
        }
        .fileImporter(
            isPresented: $viewModel.presentingAddDialog,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleAddResult(result)
        }
        .onDrop(of: [.fileURL], delegate: SidebarDropDelegate(viewModel: viewModel, deps: deps, modelContext: modelContext, onChange: reload))
        .sheet(item: $viewModel.editDraft) { draft in
            ProjectOrganizationEditor(draft: draft) { group, tags in
                saveOrganization(draft, group: group, tags: tags)
            }
        }
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(
                get: { viewModel.pendingRemoval != nil },
                set: { if !$0 { viewModel.pendingRemoval = nil } }
            ),
            presenting: viewModel.pendingRemoval
        ) { removal in
            Button(String(localized: "移除项目"), role: .destructive) {
                removeProject(removal)
            }
            Button(String(localized: "取消"), role: .cancel) {
                viewModel.pendingRemoval = nil
            }
        } message: { _ in
            Text(String(localized: "只会从 CodeReentry 中移除注册信息、关联会话与绑定；磁盘上的项目文件不会被删除。"))
        }
        .alert(
            String(localized: "项目操作失败"),
            isPresented: Binding(
                get: { viewModel.operationError != nil },
                set: { if !$0 { viewModel.operationError = nil } }
            )
        ) {
            Button(String(localized: "好")) { viewModel.operationError = nil }
        } message: {
            Text(viewModel.operationError ?? "")
        }
    }

    private func globalRow(_ destination: GlobalDestination) -> some View {
        Label(destination.title, systemImage: destination.systemImage)
            .tag(destination.selectionTag)
            .padding(.vertical, 3)
            .accessibilityHint(String(localized: "打开全局视图"))
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider()
            DevHubLocalBadge()
            HStack(spacing: 6) {
                Circle()
                    .fill(viewModel.missingProjectIds.isEmpty ? DevHubTheme.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(
                    viewModel.missingProjectIds.isEmpty
                        ? String(localized: "本地索引 · \(projectCount) 个项目")
                        : String(localized: "\(viewModel.missingProjectIds.count) 个路径需要处理")
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(DevHubTheme.secondaryInk)
            }
            Label(String(localized: "按需读取，不在后台轮询历史"), systemImage: "leaf.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                deps.requestedSettingsTab = .general
                openSettings()
            } label: {
                HStack(spacing: 8) {
                    Label(String(localized: "设置"), systemImage: "gearshape.fill")
                    Spacer()
                    Text("⌘,")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .accessibilityHint(String(localized: "打开 CodeReentry 设置"))
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    private var projectCount: Int {
        viewModel.pinnedProjects.count
            + viewModel.activeGroups.reduce(0) { $0 + $1.projects.count }
            + viewModel.archivedProjects.count
    }

    private func reload() {
        viewModel.loadProjects(from: modelContext)
    }

    private func projectRow(_ project: Project) -> some View {
        HStack {
            Image(systemName: project.icon ?? "folder.fill")
                .foregroundStyle(DevHubTheme.accent)
            Text(project.name)
                .lineLimit(1)
                .accessibilityLabel(project.name)
            Spacer()
            if viewModel.isPathMissing(for: project) {
                Label(String(localized: "路径失效"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.12), in: Capsule())
                    .help(String(localized: "项目文件夹已移动或删除"))
            }
            if !project.tags.isEmpty {
                Text(project.tags.count > 1 ? "\(project.tags[0]) +\(project.tags.count - 1)" : project.tags[0])
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Menu {
                projectActions(for: project)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(String(localized: "项目操作"))
        }
        .tag(project.stableId)
        .padding(.vertical, 3)
        .accessibilityHint(String(localized: "打开项目详情"))
        .contextMenu {
            projectActions(for: project)
        }
    }

    @ViewBuilder
    private func projectActions(for project: Project) -> some View {
        if viewModel.isPathMissing(for: project) {
            Button {
                chooseRelocationFolder(for: project)
            } label: {
                Label(String(localized: "重新定位…"), systemImage: "folder.badge.questionmark")
            }

            Divider()
        }

        Button {
            setPinned(!project.isPinned, for: project)
        } label: {
            Label(
                project.isPinned ? String(localized: "取消置顶") : String(localized: "置顶项目"),
                systemImage: project.isPinned ? "pin.slash" : "pin"
            )
        }

        Button {
            viewModel.beginEditing(project)
        } label: {
            Label(String(localized: "编辑分组与标签…"), systemImage: "tag")
        }

        Divider()

        Button(role: .destructive) {
            viewModel.requestRemoval(of: project)
        } label: {
            Label(String(localized: "移除项目…"), systemImage: "minus.circle")
        }
    }

    private func handleAddResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                _ = try viewModel.registerDroppedFolder(
                    at: url.path(percentEncoded: false), deps: deps, ctx: modelContext
                )
                reload()
            } catch {
                sidebarLogger.error("注册项目失败: \(error.localizedDescription, privacy: .public)")
                viewModel.operationError = String(localized: "无法注册该文件夹：\(error.localizedDescription)")
            }
        case .failure(let err):
            sidebarLogger.error("选择文件夹失败: \(err.localizedDescription, privacy: .public)")
            viewModel.operationError = String(localized: "无法选择文件夹：\(err.localizedDescription)")
        }
    }

    private var removalTitle: String {
        guard let removal = viewModel.pendingRemoval else {
            return String(localized: "移除项目？")
        }
        return String(localized: "从 CodeReentry 移除“\(removal.name)”？")
    }

    private func selectDestination(_ selection: String?) {
        guard let selection else {
            deps.selectedProjectStableId = nil
            deps.selectedGlobalDestination = .projects
            return
        }
        if let global = GlobalDestination(selectionTag: selection) {
            deps.selectedGlobalDestination = global
            return
        }

        deps.selectedProjectStableId = selection
        do {
            try viewModel.markOpened(stableId: selection, deps: deps, ctx: modelContext)
        } catch {
            sidebarLogger.error("更新最近打开时间失败: \(error.localizedDescription, privacy: .public)")
            viewModel.operationError = String(localized: "项目已打开，但无法更新最近使用时间。")
        }
    }

    private func setPinned(_ pinned: Bool, for project: Project) {
        do {
            try viewModel.setPinned(pinned, projectId: project.id, deps: deps, ctx: modelContext)
        } catch {
            sidebarLogger.error("更新项目置顶状态失败: \(error.localizedDescription, privacy: .public)")
            viewModel.operationError = String(localized: "无法更新“\(project.name)”的置顶状态。")
        }
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
            try viewModel.relocateProject(
                id: project.id,
                to: selectedURL.path(percentEncoded: false),
                deps: deps,
                ctx: modelContext
            )
            reload()
        } catch {
            sidebarLogger.error("重新定位项目失败: \(error.localizedDescription, privacy: .public)")
            viewModel.operationError = projectRelocationErrorMessage(error)
        }
    }

    private func saveOrganization(
        _ draft: SidebarProjectEditDraft,
        group: String,
        tags: String
    ) {
        do {
            try viewModel.updateOrganization(
                projectId: draft.id,
                group: group,
                tags: tags,
                deps: deps,
                ctx: modelContext
            )
        } catch {
            sidebarLogger.error("更新项目组织信息失败: \(error.localizedDescription, privacy: .public)")
            viewModel.operationError = String(localized: "无法保存“\(draft.name)”的分组与标签。")
        }
    }

    private func removeProject(_ removal: SidebarProjectRemoval) {
        do {
            try viewModel.removeProject(removal, deps: deps, ctx: modelContext)
            if deps.selectedProjectStableId == removal.stableId {
                deps.selectedGlobalDestination = .projects
            }
        } catch {
            sidebarLogger.error("移除项目失败: \(error.localizedDescription, privacy: .public)")
            viewModel.operationError = String(localized: "无法移除“\(removal.name)”。")
        }
    }
}

private struct ProjectOrganizationEditor: View {
    @Environment(\.dismiss) private var dismiss
    let draft: SidebarProjectEditDraft
    let onSave: (String, String) -> Void

    @State private var group: String
    @State private var tags: String

    init(draft: SidebarProjectEditDraft, onSave: @escaping (String, String) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _group = State(initialValue: draft.group)
        _tags = State(initialValue: draft.tags)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(localized: "整理项目"))
                    .font(.title2.bold())
                Text(draft.name)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField(String(localized: "分组"), text: $group, prompt: Text(SidebarViewModel.defaultGroupName))
                TextField(String(localized: "标签"), text: $tags, prompt: Text(String(localized: "例如：客户端, Swift")))
            }
            .formStyle(.grouped)
            .frame(height: 120)

            Text(String(localized: "多个标签请用逗号分隔；分组留空时项目会显示在“其他”中。"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(String(localized: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "保存")) {
                    onSave(group, tags)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// 拖拽注册：拖入文件夹即注册为项目
struct SidebarDropDelegate: DropDelegate {
    let viewModel: SidebarViewModel
    let deps: AppDependencies
    let modelContext: ModelContext
    let onChange: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.fileURL]).first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async {
                do {
                    _ = try viewModel.registerDroppedFolder(at: url.path, deps: deps, ctx: modelContext)
                    onChange()
                } catch {
                    sidebarLogger.error("拖拽注册失败: \(error.localizedDescription, privacy: .public)")
                    viewModel.operationError = String(localized: "无法注册拖入的文件夹：\(error.localizedDescription)")
                }
            }
        }
        return true
    }
}
