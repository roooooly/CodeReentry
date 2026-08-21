import AppKit
import Observation
import SwiftUI
import SwiftData
import DevHubCore

struct SettingsView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.modelContext) private var ctx
    @State private var viewModel = SettingsViewModel()
    @State private var loadErrorMessage: String?

    var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            GeneralSettingsTab().tag(SettingsTab.general)
                .tabItem { Label(String(localized: "通用"), systemImage: "gearshape") }
            ToolsSettingsTab().tag(SettingsTab.tools)
                .tabItem { Label(String(localized: "工具"), systemImage: "wrench.and.screwdriver") }
            MCPSettingsSection().tag(SettingsTab.mcp)
                .tabItem { Label(String(localized: "MCP"), systemImage: "network") }
            PluginSettingsSection().tag(SettingsTab.plugins)
                .tabItem { Label(String(localized: "插件"), systemImage: "puzzlepiece.extension") }
        }
        .environment(viewModel)
        .frame(width: 700, height: 560)
        .task {
            do {
                try viewModel.load(ctx: ctx, deps: deps)
            } catch {
                loadErrorMessage = error.localizedDescription
            }
            viewModel.consumeRequestedTab(from: deps)
        }
        .onChange(of: deps.requestedSettingsTab) { _, _ in
            viewModel.consumeRequestedTab(from: deps)
        }
        .alert(
            String(localized: "加载设置失败"),
            isPresented: Binding(
                get: { loadErrorMessage != nil },
                set: { if !$0 { loadErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "好")) { loadErrorMessage = nil }
        } message: {
            Text(loadErrorMessage ?? "")
        }
    }
}

// MARK: - 通用 tab

private struct GeneralSettingsTab: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.modelContext) private var ctx
    @Environment(SettingsViewModel.self) private var viewModel
    @State private var showLogPrivacyConfirmation = false
    @State private var generalErrorMessage: String?
    @State private var lastLogExportURL: URL?

    var body: some View {
        @Bindable var vm = viewModel
        Form {
            Section(String(localized: "项目根目录")) {
                HStack {
                    TextField(String(localized: "路径"), text: $vm.general.projectsRoot)
                    Button(String(localized: "选择…")) { chooseProjectsRoot() }
                }
                Label(
                    viewModel.projectsRootIsAvailable
                        ? String(localized: "目录可用")
                        : String(localized: "目录不存在；项目扫描会等待路径恢复"),
                    systemImage: viewModel.projectsRootIsAvailable
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(viewModel.projectsRootIsAvailable ? DevHubTheme.green : .orange)
            }
            Section(String(localized: "主题")) {
                Picker(String(localized: "主题"), selection: $vm.general.theme) {
                    Text(String(localized: "跟随系统")).tag("system")
                    Text(String(localized: "浅色")).tag("light")
                    Text(String(localized: "深色")).tag("dark")
                }
            }
            Section(String(localized: "语言")) {
                Picker(String(localized: "语言"), selection: $vm.general.locale) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                Text(String(localized: "语言会应用到主窗口、设置、菜单和系统提示。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if viewModel.languageChangeRequiresRestart {
                    Label(
                        String(localized: "语言已保存；退出并重新打开 CodeReentry 后生效。"),
                        systemImage: "arrow.clockwise.circle.fill"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(DevHubTheme.accent)
                }
            }
            Section(String(localized: "项目详情模块")) {
                ForEach(DetailTab.allCases) { tab in
                    Toggle(isOn: detailTabBinding(for: tab)) {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .disabled(
                        deps.enabledDetailTabs.count == 1
                            && deps.isDetailTabEnabled(tab)
                    )
                }
                Text(String(localized: "关闭的模块不会出现在项目详情或命令面板中；至少保留一个模块。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(String(localized: "系统")) {
                Toggle(String(localized: "登录时启动 CodeReentry"), isOn: launchAtLoginBinding)
                if let message = launchAtLoginStatusMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(
                            viewModel.launchAtLoginState == .requiresApproval
                                ? AnyShapeStyle(.orange)
                                : AnyShapeStyle(.secondary)
                        )
                }

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(localized: "诊断日志"))
                        Text(String(localized: "仅导出最近 7 天、subsystem 为 io.github.roooooly.devhub 的统一日志。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if viewModel.isExportingLogs {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Button(String(localized: "导出日志…")) {
                        showLogPrivacyConfirmation = true
                    }
                    .disabled(viewModel.isExportingLogs)
                }

                if let lastLogExportURL {
                    Text(String(localized: "已保存：\(lastLogExportURL.path)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }

            Section {
                HStack {
                    Text(String(localized: "设置会自动保存在本机。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "恢复通用设置默认值")) {
                        do {
                            try viewModel.restoreGeneralDefaults(ctx: ctx, deps: deps)
                        } catch {
                            generalErrorMessage = error.localizedDescription
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: vm.general.projectsRoot) { _, _ in saveGeneral(vm) }
        .onChange(of: vm.general.theme) { _, _ in saveGeneral(vm) }
        .onChange(of: vm.general.locale) { _, _ in saveGeneral(vm) }
        .confirmationDialog(
            String(localized: "导出最近 7 天 CodeReentry 日志？"),
            isPresented: $showLogPrivacyConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "确认并选择保存位置")) {
                chooseLogExportDestination()
            }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "统一日志可能包含项目路径、工具名和错误上下文。CodeReentry 只查询自己的 subsystem，并会再次遮罩疑似 token、密钥和密码；分享前仍请检查文件内容。"))
        }
        .alert(
            String(localized: "通用设置失败"),
            isPresented: Binding(
                get: { generalErrorMessage != nil },
                set: { if !$0 { generalErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "好")) { generalErrorMessage = nil }
        } message: {
            Text(generalErrorMessage ?? "")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { viewModel.launchAtLoginRequested },
            set: { enabled in
                do {
                    try viewModel.setLaunchAtLogin(enabled, deps: deps)
                } catch {
                    generalErrorMessage = error.localizedDescription
                }
            }
        )
    }

    private func saveGeneral(_ viewModel: SettingsViewModel) {
        do {
            try viewModel.saveGeneral(ctx: ctx, deps: deps)
        } catch {
            generalErrorMessage = error.localizedDescription
        }
    }

    private func chooseProjectsRoot() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择项目根目录")
        panel.message = String(localized: "CodeReentry 只扫描该目录下一层的项目候选。")
        panel.prompt = String(localized: "选择")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if viewModel.projectsRootIsAvailable {
            panel.directoryURL = URL(fileURLWithPath: viewModel.standardizedProjectsRoot)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        viewModel.general.projectsRoot = url.path(percentEncoded: false)
    }

    private func detailTabBinding(for tab: DetailTab) -> Binding<Bool> {
        Binding(
            get: { deps.isDetailTabEnabled(tab) },
            set: { enabled in
                do {
                    try deps.setDetailTab(tab, enabled: enabled)
                } catch {
                    generalErrorMessage = error.localizedDescription
                }
            }
        )
    }

    private var launchAtLoginStatusMessage: String? {
        switch viewModel.launchAtLoginState {
        case .disabled:
            return nil
        case .enabled:
            return String(localized: "已启用；下次登录 macOS 时会自动启动。")
        case .requiresApproval:
            return String(localized: "等待系统批准。请前往“系统设置 → 通用 → 登录项”允许 CodeReentry。")
        case .unavailable:
            return String(localized: "当前签名或运行方式不支持登录项；正式签名的 CodeReentry.app 可在此启用。")
        }
    }

    private func chooseLogExportDestination() {
        let panel = NSSavePanel()
        panel.title = String(localized: "保存 CodeReentry 诊断日志")
        panel.prompt = String(localized: "导出")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "CodeReentry-logs-\(formatter.string(from: Date())).ndjson"

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in
            do {
                let result = try await viewModel.exportLastSevenDaysOfLogs(
                    to: destination,
                    privacyConfirmed: true,
                    deps: deps
                )
                lastLogExportURL = result.url
            } catch {
                generalErrorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - 工具 tab

private struct ToolsSettingsTab: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.modelContext) private var ctx
    @Environment(SettingsViewModel.self) private var viewModel

    @State private var secretPrompt: SecretPrompt?
    @State private var errorMessage: String?
    @State private var pendingToolDeletion: Tool?

    struct SecretPrompt: Identifiable {
        let id = UUID()
        let tool: Tool
        let envKey: String
        let isUpdate: Bool
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Text(String(localized: "工具会自动绑定到新注册的项目，也可在每个工具下单独调整。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Menu(String(localized: "添加工具")) {
                        Button(String(localized: "CLI 工具")) {
                            do { try viewModel.addTool(kind: .cli, ctx: ctx) }
                            catch { errorMessage = error.localizedDescription }
                        }
                        Button(String(localized: "macOS App")) {
                            do { try viewModel.addTool(kind: .app, ctx: ctx) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    Button(String(localized: "恢复内置工具")) {
                        do { try viewModel.restoreDefaultTools(ctx: ctx, deps: deps) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }

            ForEach(viewModel.tools) { tool in
                Section {
                    ToolEditRow(
                        tool: tool,
                        projects: viewModel.projects,
                        isBuiltInAdapter: viewModel.usesBuiltInAdapter(tool),
                        secretDisplay: {
                            viewModel.secretDisplay(tool: tool, envKey: $0, deps: deps)
                        },
                        onSave: {
                            do { try viewModel.saveTools(ctx: ctx) }
                            catch { errorMessage = error.localizedDescription }
                        },
                        onSetProjectBinding: { project, enabled in
                            do { try viewModel.setBinding(tool: tool, project: project, enabled: enabled, ctx: ctx) }
                            catch { errorMessage = error.localizedDescription }
                        },
                        onSetEnvironment: { key, value in
                            do { try viewModel.setEnvironmentVariable(tool: tool, key: key, value: value, ctx: ctx) }
                            catch { errorMessage = error.localizedDescription }
                        },
                        onDeleteEnvironment: { key in
                            do { try viewModel.deleteEnvironmentVariable(tool: tool, key: key, ctx: ctx) }
                            catch { errorMessage = error.localizedDescription }
                        },
                        onAddSecret: { key in secretPrompt = SecretPrompt(tool: tool, envKey: key, isUpdate: false) },
                        onUpdateSecret: { key in secretPrompt = SecretPrompt(tool: tool, envKey: key, isUpdate: true) },
                        onDeleteSecret: { key in
                            do { try viewModel.deleteSecretEnvKey(tool: tool, envKey: key, deps: deps) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    )
                } header: {
                    HStack {
                        Text(tool.name)
                        Spacer()
                        Button(role: .destructive) {
                            pendingToolDeletion = tool
                        } label: {
                            Label(String(localized: "删除工具"), systemImage: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .sheet(item: $secretPrompt) { prompt in
            SecretEntrySheet(
                title: prompt.isUpdate ? String(localized: "更新密钥值") : String(localized: "录入密钥值"),
                keyName: prompt.envKey,
                onSubmit: { value in
                    if prompt.isUpdate {
                        try viewModel.updateSecretEnvKey(tool: prompt.tool, envKey: prompt.envKey, value: value, deps: deps)
                    } else {
                        try viewModel.addSecretEnvKey(tool: prompt.tool, envKey: prompt.envKey, value: value, deps: deps)
                    }
                },
                onSuccess: { secretPrompt = nil },
                onCancel: { secretPrompt = nil }
            )
        }
        .alert(String(localized: "工具设置失败"),
               isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(String(localized: "好")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "删除工具？"),
            isPresented: Binding(
                get: { pendingToolDeletion != nil },
                set: { if !$0 { pendingToolDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingToolDeletion
        ) { tool in
            Button(String(localized: "删除 \(tool.name)"), role: .destructive) {
                pendingToolDeletion = nil
                do {
                    try viewModel.deleteTool(tool, ctx: ctx, deps: deps)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button(String(localized: "取消"), role: .cancel) {
                pendingToolDeletion = nil
            }
        } message: { tool in
            Text(String(localized: "将删除“\(tool.name)”及其 \(tool.secretEnvKeys.count) 个 Keychain 密钥引用，并移除 \(tool.projects.count) 个项目绑定。此操作无法撤销。"))
        }
    }
}

private struct ToolEditRow: View {
    let tool: Tool
    let projects: [Project]
    let isBuiltInAdapter: Bool
    let secretDisplay: (String) -> String
    let onSave: () -> Void
    let onSetProjectBinding: (Project, Bool) -> Void
    let onSetEnvironment: (String, String) -> Void
    let onDeleteEnvironment: (String) -> Void
    let onAddSecret: (String) -> Void
    let onUpdateSecret: (String) -> Void
    let onDeleteSecret: (String) -> Void

    @State private var newSecretKey = ""
    @State private var newEnvKey = ""
    @State private var newEnvValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(String(localized: "工具名"), text: bindName).frame(maxWidth: 220)
                Picker(String(localized: "类型"), selection: bindKind) {
                    Text("CLI").tag(ToolKind.cli)
                    Text("App").tag(ToolKind.app)
                }
                .labelsHidden()
                .frame(width: 90)
                .disabled(isBuiltInAdapter)
                Toggle(String(localized: "启用"), isOn: bindEnabled)
            }
            TextField(
                tool.kind == .app
                    ? String(localized: "Bundle ID 或 .app 路径")
                    : String(localized: "可执行路径或命令（可含固定参数）"),
                text: bindCommand
            )
            Picker(String(localized: "工作目录"), selection: bindWorkingDirMode) {
                Text(String(localized: "项目根目录")).tag(WorkingDirMode.projectRoot)
                Text(String(localized: "自定义目录")).tag(WorkingDirMode.custom)
            }
            if tool.workingDirMode == .custom {
                TextField(String(localized: "自定义工作目录"), text: bindCustomWorkingDir)
            }
            if tool.kind == .cli {
                Toggle(String(localized: "允许发送项目记忆"), isOn: bindInject)
                if isBuiltInAdapter {
                    Text(String(localized: "内置工具的实际注入方式由已验证的 adapter 决定，不能在此降级安全策略。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if tool.injectMemory {
                    Picker(String(localized: "注入方式"), selection: bindInjectionMode) {
                        Text(String(localized: "提示文件参数")).tag(InjectionMode.cliFlag)
                        Text(String(localized: "位置参数")).tag(InjectionMode.positionalArg)
                        Text(String(localized: "复制到剪贴板（需手动粘贴）")).tag(InjectionMode.clipboard)
                    }
                    if tool.injectionMode != .clipboard {
                        TextEditor(text: bindInjectionArguments)
                            .font(.body.monospaced())
                            .frame(minHeight: 56, maxHeight: 90)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                        Text(tool.injectionMode == .cliFlag
                             ? String(localized: "每行是一个 argv；必须有一行完全等于 {memoryFile}。")
                             : String(localized: "每行是一个 argv；必须有一行完全等于 {memory}。位置参数会执行敏感信息阻断。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(String(localized: "启动时只会复制项目记忆，不会模拟粘贴或回车；请在目标 CLI 中手动粘贴。内容未变化时会在 30 秒后清理，剪贴板历史工具仍可能保留副本。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            DisclosureGroup(String(localized: "绑定项目")) {
                if projects.isEmpty {
                    Text(String(localized: "尚无项目"))
                        .foregroundStyle(.secondary)
                }
                ForEach(projects) { project in
                    Toggle(project.name, isOn: Binding(
                        get: { tool.projects.contains { $0.id == project.id } },
                        set: { onSetProjectBinding(project, $0) }
                    ))
                }
            }

            DisclosureGroup(String(localized: "普通环境变量")) {
                ForEach(tool.envVars.keys.sorted(), id: \.self) { key in
                    HStack {
                        Text(key).monospaced()
                        Text(tool.envVars[key] ?? "")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button(String(localized: "删除"), role: .destructive) { onDeleteEnvironment(key) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                HStack {
                    TextField(String(localized: "变量名"), text: $newEnvKey).frame(width: 170)
                    TextField(String(localized: "值"), text: $newEnvValue)
                    Button(String(localized: "添加")) {
                        onSetEnvironment(newEnvKey, newEnvValue)
                        newEnvKey = ""; newEnvValue = ""
                    }
                    .disabled(newEnvKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            DisclosureGroup(String(localized: "敏感环境变量 (Keychain)")) {
                ForEach(tool.secretEnvKeys, id: \.self) { key in
                    HStack {
                        Text(key).font(.body)
                        Spacer()
                        Text(secretDisplay(key))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(String(localized: "更新")) { onUpdateSecret(key) }
                            .buttonStyle(.bordered).controlSize(.small)
                        Button(String(localized: "删除"), role: .destructive) { onDeleteSecret(key) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                    .accessibilityLabel("\(key) \(secretDisplay(key))")
                }
                HStack {
                    TextField(String(localized: "新增 key 名（如 OPENAI_API_KEY）"), text: $newSecretKey)
                        .frame(maxWidth: 250)
                    Button(String(localized: "录入值")) {
                        let k = newSecretKey.trimmingCharacters(in: .whitespaces)
                        guard !k.isEmpty else { return }
                        onAddSecret(k)
                        newSecretKey = ""
                    }
                    .disabled(newSecretKey.isEmpty)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var bindName: Binding<String> {
        Binding(get: { tool.name }, set: { tool.name = $0; onSave() })
    }
    private var bindCommand: Binding<String> {
        Binding(get: { tool.launchCommand }, set: { tool.launchCommand = $0; onSave() })
    }
    private var bindKind: Binding<ToolKind> {
        Binding(get: { tool.kind }, set: { tool.kind = $0; onSave() })
    }
    private var bindInject: Binding<Bool> {
        Binding(get: { tool.injectMemory }, set: { tool.injectMemory = $0; onSave() })
    }
    private var bindEnabled: Binding<Bool> {
        Binding(get: { tool.enabled }, set: { tool.enabled = $0; onSave() })
    }
    private var bindWorkingDirMode: Binding<WorkingDirMode> {
        Binding(get: { tool.workingDirMode }, set: { tool.workingDirMode = $0; onSave() })
    }
    private var bindInjectionMode: Binding<InjectionMode> {
        Binding(get: { tool.injectionMode }, set: { tool.injectionMode = $0; onSave() })
    }
    private var bindInjectionArguments: Binding<String> {
        Binding(
            get: { (tool.injectionArgs ?? []).joined(separator: "\n") },
            set: { value in
                let arguments = value
                    .components(separatedBy: .newlines)
                    .filter { !$0.isEmpty }
                tool.injectionArgs = arguments.isEmpty ? nil : arguments
                onSave()
            }
        )
    }
    private var bindCustomWorkingDir: Binding<String> {
        Binding(
            get: { tool.customWorkingDir ?? "" },
            set: { tool.customWorkingDir = $0.isEmpty ? nil : $0; onSave() }
        )
    }
}

@MainActor
@Observable
final class SecretEntryFormModel {
    var value = ""
    var errorMessage: String?
    private(set) var isSubmitting = false

    @discardableResult
    func submit(_ action: (String) throws -> Void) -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try action(value)
            errorMessage = nil
            return true
        } catch {
            // 保留 value，让用户可以修正环境或直接重试；只有成功时外层才关闭 sheet。
            errorMessage = error.localizedDescription
            return false
        }
    }
}

private struct SecretEntrySheet: View {
    let title: String
    let keyName: String
    let onSubmit: (String) throws -> Void
    let onSuccess: () -> Void
    let onCancel: () -> Void
    @State private var formModel = SecretEntryFormModel()

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.headline)
            Text(keyName).foregroundStyle(.secondary)
            SecureField(String(localized: "密钥值"), text: $formModel.value)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(String(localized: "取消"), action: onCancel)
                Spacer()
                Button(String(localized: "保存")) {
                    if formModel.submit(onSubmit) {
                        onSuccess()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(formModel.value.isEmpty || formModel.isSubmitting)
            }
        }
        .padding(24)
        .frame(width: 380)
        .alert(
            String(localized: "密钥写入失败"),
            isPresented: Binding(
                get: { formModel.errorMessage != nil },
                set: { if !$0 { formModel.errorMessage = nil } }
            )
        ) {
            Button(String(localized: "好")) { formModel.errorMessage = nil }
        } message: {
            Text(formModel.errorMessage ?? "")
        }
    }
}
