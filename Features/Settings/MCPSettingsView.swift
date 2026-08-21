import SwiftUI
import Observation
import DevHubCore

@MainActor
@Observable
final class MCPSettingsViewModel {
    let store: MCPConfigStore
    private(set) var supervisor: MCPClientSupervisor?
    var serverNames: [String] = []
    var serverSnapshots: [MCPServerSnapshot] = []
    var tools: [MCPToolInfo] = []
    var pendingConfirmation: MCPConfirmationGate?
    var newName = ""
    var newCommand = ""
    var newArgs = ""
    var selectedToolId: String?
    var toolArgumentsJSON = "{}"
    var toolResult: MCPToolCallResult?
    var errorMessage: String?
    private(set) var configurationLoadError: String?
    private(set) var hasLoadedConfiguration = false
    var runtimeLoading = false

    init(store: MCPConfigStore, supervisor: MCPClientSupervisor? = nil) {
        self.store = store
        self.supervisor = supervisor
    }

    func attach(supervisor: MCPClientSupervisor) { self.supervisor = supervisor }

    func load() {
        hasLoadedConfiguration = true
        do {
            serverNames = try store.load().servers.keys.sorted()
            configurationLoadError = nil
            errorMessage = nil
        } catch {
            serverNames = []
            serverSnapshots = []
            tools = []
            selectedToolId = nil
            toolResult = nil
            let message = String(localized: "无法读取 mcp.json：") + error.localizedDescription
            configurationLoadError = message
            errorMessage = message
        }
    }

    var canModifyConfiguration: Bool {
        hasLoadedConfiguration && configurationLoadError == nil
    }

    func requestAdd() {
        guard canModifyConfiguration else {
            errorMessage = configurationLoadError
                ?? String(localized: "MCP 配置尚未加载，请先重新读取。")
            return
        }
        let argTokens: [String]
        do {
            argTokens = try ConfiguredCommand.tokenize(newArgs)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let server = MCPServerConfig(command: newCommand, args: argTokens, env: nil)
        let name = newName.trimmingCharacters(in: .whitespaces).isEmpty ? "new-server" : newName.trimmingCharacters(in: .whitespaces)
        pendingConfirmation = MCPConfirmationGate(serverName: name, server: server)
    }

    func confirmAdd(decision: MCPConfirmationDecision) throws {
        defer { pendingConfirmation = nil }
        guard decision == .accepted, let gate = pendingConfirmation else { return }
        guard canModifyConfiguration else {
            throw MCPSettingsError.configurationUnavailable
        }
        try store.addServer(name: gate.serverName, command: gate.server.command, args: gate.server.args, env: gate.server.env)
        load()
        newName = ""; newCommand = ""; newArgs = ""
    }

    func removeServer(_ name: String) {
        guard canModifyConfiguration else {
            errorMessage = configurationLoadError
                ?? MCPSettingsError.configurationUnavailable.localizedDescription
            return
        }
        do {
            try store.removeServer(name: name)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var selectedTool: MCPToolInfo? {
        tools.first { $0.id == selectedToolId }
    }

    func status(for serverName: String) -> MCPClientStatus {
        serverSnapshots.first { $0.name == serverName }?.status ?? .disconnected
    }

    func refreshRuntime(reload: Bool) async {
        guard let supervisor else { return }
        guard canModifyConfiguration else {
            serverSnapshots = []
            tools = []
            selectedToolId = nil
            return
        }
        runtimeLoading = true
        if reload { await supervisor.reload() }
        serverSnapshots = supervisor.snapshots()
        tools = await supervisor.allToolInfos()
        if selectedTool == nil { selectedToolId = tools.first?.id }
        runtimeLoading = false
    }

    func callSelectedTool() async {
        guard let supervisor, let tool = selectedTool else { return }
        runtimeLoading = true
        toolResult = nil
        do {
            toolResult = try await supervisor.callTool(
                serverName: tool.serverName,
                toolName: tool.name,
                argumentsJSON: toolArgumentsJSON
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        runtimeLoading = false
    }
}

enum MCPSettingsError: Error, LocalizedError, Equatable {
    case configurationUnavailable

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            return String(localized: "mcp.json 无法解析。为保留原文件，修复前不能添加或删除 server。")
        }
    }
}

/// MCP 首次启用确认弹窗（§6.3）。
struct MCPConfirmationView: View {
    let gate: MCPConfirmationGate
    let onComplete: (MCPConfirmationDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "确认启用 MCP server"))
                .font(.headline)
            ScrollView { Text(gate.confirmationPrompt).font(.system(.body, design: .monospaced)) }
                .frame(maxHeight: 180)
            if !gate.warningLines.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(gate.warningLines, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }
            }
            HStack {
                Button(String(localized: "取消"), role: .cancel) { onComplete(.declined) }
                Spacer()
                Button(String(localized: "确认启用")) { onComplete(.accepted) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "MCP server 启用确认"))
    }
}

/// Settings 中 MCP tab 的内容（替换 P0 placeholder）。
struct MCPSettingsSection: View {
    @Environment(AppDependencies.self) private var deps
    @State private var vm: MCPSettingsViewModel
    @State private var confirmingToolCall = false

    init(store: MCPConfigStore = MCPConfigStore()) {
        _vm = State(initialValue: MCPSettingsViewModel(store: store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "MCP Servers（stdio）"))
                    .font(.headline)
                Spacer()
                if vm.runtimeLoading { ProgressView().controlSize(.small) }
                Button(String(localized: "重连并刷新")) {
                    Task { await vm.refreshRuntime(reload: true) }
                }
                .disabled(vm.runtimeLoading || !vm.canModifyConfiguration)
            }
            if let configurationLoadError = vm.configurationLoadError {
                VStack(alignment: .leading, spacing: 6) {
                    Label(String(localized: "MCP 配置已进入只读保护状态"), systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(configurationLoadError)
                        .font(.caption)
                    Text(storePathDescription)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(String(localized: "CodeReentry 不会覆盖该文件。请在外部修复 JSON 后重新读取。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(String(localized: "重新读取配置")) {
                        vm.load()
                        if vm.canModifyConfiguration {
                            Task { await vm.refreshRuntime(reload: true) }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(10)
                .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain)
            } else if vm.serverNames.isEmpty {
                Text(String(localized: "尚未配置 MCP server。"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(vm.serverNames, id: \.self) { name in
                    HStack {
                        Image(systemName: "network").foregroundStyle(.secondary)
                        Text(name)
                        Text(vm.status(for: name).localizedDescription)
                            .font(.caption)
                            .foregroundStyle(
                                vm.status(for: name).isUsable
                                    ? Color.green
                                    : Color(nsColor: .secondaryLabelColor)
                            )
                        Spacer()
                        Button(String(localized: "删除"), role: .destructive) {
                            vm.removeServer(name)
                            if vm.canModifyConfiguration {
                                Task { await vm.refreshRuntime(reload: true) }
                            }
                        }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint(String(localized: "从 mcp.json 移除 \(name)"))
                    }
                    Divider()
                }
            }

            if !vm.tools.isEmpty {
                Divider()
                Text(String(localized: "已发现工具")).font(.headline)
                Picker(String(localized: "MCP 工具"), selection: Binding(
                    get: { vm.selectedToolId ?? "" },
                    set: { vm.selectedToolId = $0; vm.toolResult = nil }
                )) {
                    ForEach(vm.tools) { tool in
                        Text("\(tool.serverName) · \(tool.title)").tag(tool.id)
                    }
                }
                if let tool = vm.selectedTool {
                    if let description = tool.description {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup(String(localized: "输入 Schema")) {
                        ScrollView {
                            Text(tool.inputSchemaJSON)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 100)
                    }
                    Text(String(localized: "参数 JSON")).font(.subheadline)
                    TextEditor(text: $vm.toolArgumentsJSON)
                        .font(.body.monospaced())
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(nsColor: .separatorColor)))
                    Button(String(localized: "执行工具（需确认）")) {
                        confirmingToolCall = true
                    }
                    .disabled(vm.runtimeLoading || !vm.canModifyConfiguration)
                    if let result = vm.toolResult {
                        ScrollView {
                            Text(result.text.isEmpty ? String(localized: "工具没有返回文本内容。") : result.text)
                                .font(.caption.monospaced())
                                .foregroundStyle(result.isError ? .red : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 120)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "添加 server（首次需确认）"))
                    .font(.subheadline)
                TextField(String(localized: "名称（如 filesystem）"), text: $vm.newName)
                    .textFieldStyle(.roundedBorder)
                TextField(String(localized: "command（如 npx）"), text: $vm.newCommand)
                    .textFieldStyle(.roundedBorder)
                TextField(String(localized: "args（空格分隔，如 -y @modelcontextprotocol/server-filesystem /path）"), text: $vm.newArgs)
                    .textFieldStyle(.roundedBorder)
                Button(String(localized: "添加（需确认）")) { vm.requestAdd() }
                    .disabled(vm.newCommand.isEmpty || !vm.canModifyConfiguration)
            }
            .disabled(!vm.canModifyConfiguration)
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            vm.attach(supervisor: deps.mcpSupervisor)
            vm.load()
            await vm.refreshRuntime(reload: false)
        }
        .alert(String(localized: "MCP 操作失败"),
               isPresented: Binding(get: { vm.errorMessage != nil }, set: { if !$0 { vm.errorMessage = nil } })) {
            Button(String(localized: "好")) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "确认执行 MCP 工具"),
            isPresented: $confirmingToolCall,
            titleVisibility: .visible
        ) {
            Button(String(localized: "执行")) { Task { await vm.callSelectedTool() } }
            Button(String(localized: "取消"), role: .cancel) {}
        } message: {
            Text(String(localized: "将调用 \(vm.selectedTool?.serverName ?? "") / \(vm.selectedTool?.name ?? "")。MCP server 可能读写文件、访问网络或启动进程，请确认参数与 server 来源可信。"))
        }
        .sheet(item: Binding(
            get: { vm.pendingConfirmation },
            set: { vm.pendingConfirmation = $0 }
        )) { gate in
            MCPConfirmationView(gate: gate) { decision in
                do {
                    try vm.confirmAdd(decision: decision)
                    if decision == .accepted {
                        Task { await vm.refreshRuntime(reload: true) }
                    }
                } catch {
                    vm.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var storePathDescription: String {
        vm.store.configPath.path
    }
}
