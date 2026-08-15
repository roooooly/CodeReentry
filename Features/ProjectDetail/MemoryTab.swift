import SwiftUI
import DevHubCore

struct MemoryTab: View {
    let project: Project
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel = MemoryTabViewModel()

    var body: some View {
        VStack(spacing: 0) {
            headerToolbar
            Divider()
            contextEditor
            Divider()
            lastSummarySection
        }
        .padding()
        .task(id: project.path) {
            viewModel.activate(
                projectID: project.stableId,
                projectPath: project.path,
                deps: deps
            )
        }
        .onDisappear {
            viewModel.flushPendingSave(deps: deps)
        }
        .alert(
            String(localized: "保存项目记忆失败"),
            isPresented: Binding(
                get: { viewModel.saveError != nil },
                set: { if !$0 { viewModel.saveError = nil } }
            )
        ) {
            Button(String(localized: "重试")) {
                if viewModel.loadedProjectID == project.stableId,
                   viewModel.loadedProjectPath == project.path {
                    viewModel.flushPendingSave(deps: deps)
                } else {
                    viewModel.activate(
                        projectID: project.stableId,
                        projectPath: project.path,
                        deps: deps
                    )
                }
            }
            Button(String(localized: "稍后"), role: .cancel) {
                viewModel.saveError = nil
            }
        } message: {
            Text(viewModel.saveError ?? "")
        }
    }

    private var headerToolbar: some View {
        HStack {
            Text(String(localized: "项目记忆（context.md）"))
                .font(.headline)
            if viewModel.dirty {
                Label(String(localized: "等待自动保存"), systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if viewModel.loadedProjectID == project.stableId {
                Label(String(localized: "已保存"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Spacer()
            if viewModel.contextMd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               viewModel.loadedProjectID == project.stableId {
                Button {
                    if viewModel.insertStarterTemplate() {
                        viewModel.scheduleAutosave(deps: deps)
                    }
                } label: {
                    Label(String(localized: "插入模板"), systemImage: "doc.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(String(localized: "插入目标、约束、命令和下一步的基础结构"))
            }
            Picker("", selection: $viewModel.isPreview) {
                Text(String(localized: "编辑")).tag(false)
                Text(String(localized: "预览")).tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .accessibilityLabel(String(localized: "编辑/预览切换"))
            if viewModel.dirty {
                Button(String(localized: "保存")) {
                    viewModel.flushPendingSave(deps: deps)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint(String(localized: "保存对项目记忆的修改"))
            }
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var contextEditor: some View {
        if let err = viewModel.loadError {
            Text(String(localized: "加载失败: \(err)"))
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadedProjectID = viewModel.loadedProjectID,
                  loadedProjectID != project.stableId
                    || viewModel.loadedProjectPath != project.path {
            ContentUnavailableView {
                Label(String(localized: "上一项目的记忆尚未保存"), systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(String(localized: "为避免把草稿写入错误项目，DevHub 已暂停切换。请重试保存。"))
            } actions: {
                Button(String(localized: "重试保存并切换")) {
                    viewModel.activate(
                        projectID: project.stableId,
                        projectPath: project.path,
                        deps: deps
                    )
                }
                .buttonStyle(.borderedProminent)
            }
        } else if viewModel.isPreview {
            ScrollView {
                Text(viewModel.renderedPreview)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .accessibilityLabel(String(localized: "项目记忆预览"))
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        } else {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.contextMd)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .onChange(of: viewModel.contextMd) { _, _ in
                        viewModel.markDirtyIfNeeded()
                        viewModel.scheduleAutosave(deps: deps)
                    }
                    .accessibilityLabel(String(localized: "项目记忆编辑器"))
                    .accessibilityHint(String(localized: "编辑 .devhub/memory/context.md"))
                if viewModel.contextMd.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "写下工具真正需要复用的项目上下文"))
                            .font(.headline)
                        Text(String(localized: "建议只保留目标、不可违反的约束、关键命令和当前下一步。不要粘贴密钥或整段聊天记录。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .allowsHitTesting(false)
                }
            }
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var lastSummarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "上次会话总结（只读）"))
                    .font(.headline)
                Spacer()
                Text(String(localized: "在 Sessions tab 中点「生成本会话总结」以更新"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if viewModel.hasLastSummary {
                ScrollView {
                    Text(viewModel.lastSummaryMd)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(String(localized: "上次会话总结内容"))
            } else {
                Label(
                    String(localized: "尚无总结；可在“会话”页选择一条会话生成。"),
                    systemImage: "doc.text.magnifyingglass"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 12)
            }
        }
        .padding(.top, 8)
    }
}
