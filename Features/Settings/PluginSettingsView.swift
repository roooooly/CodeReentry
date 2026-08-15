import SwiftUI
import Observation
import DevHubCore

// MARK: - 启用确认 Gate（值类型，仿 MCPConfirmationGate）

/// 插件首次启用确认载荷（§6.4）。
struct PluginEnableConfirmationGate: Identifiable, Equatable, Sendable {
    let pluginId: String
    let name: String
    let version: String
    let permissions: [ScriptPluginPermission]
    var id: String { pluginId }

    /// 权限的人类可读描述。
    var permissionSummary: String {
        permissions.map { Self.label(for: $0) }.joined(separator: "、")
    }

    /// 警告行（automation 权限单独高亮）。
    var warningLines: [String] {
        var lines: [String] = []
        if permissions.contains(.automation) {
            lines.append(String(localized: "此插件申请 automation 权限（AppleScript 可控 Finder/模拟键鼠/读 Keychain），攻击面大。确认信任来源后启用。"))
        }
        if permissions.contains(.process) {
            lines.append(String(localized: "可启动子进程，注意脚本来源是否可信。"))
        }
        return lines
    }

    static func label(for p: ScriptPluginPermission) -> String {
        switch p {
        case .filesystem: return String(localized: "文件系统")
        case .network:    return String(localized: "网络")
        case .process:    return String(localized: "子进程")
        case .automation: return String(localized: "自动化")
        }
    }
}

enum PluginEnableDecision: Sendable, Equatable { case accepted, declined }

// MARK: - ViewModel

@MainActor
@Observable
final class PluginEnableViewModel {
    static let commandsChangedNotification = Notification.Name("DevHubPluginCommandsChanged")

    let registry: ScriptPluginRegistry
    let store: ScriptPluginPermissionStore
    private let notificationCenter: NotificationCenter
    var plugins: [DiscoveredScriptPlugin] = []
    var enabledIds: Set<String> = []
    var pendingEnable: PluginEnableConfirmationGate?
    var pendingDisable: String?  // pluginId 待禁用（确认）
    var loadError: String?

    init(
        registry: ScriptPluginRegistry = ScriptPluginRegistry(root: ScriptPluginRegistry.defaultRoot),
        store: ScriptPluginPermissionStore = ScriptPluginPermissionStore(file: ScriptPluginPermissionStore.defaultPermissionsFile),
        notificationCenter: NotificationCenter = .default
    ) {
        self.registry = registry
        self.store = store
        self.notificationCenter = notificationCenter
    }

    func load() async {
        plugins = registry.scan()
        var ids: Set<String> = []
        for p in plugins {
            if await store.isConfirmed(pluginId: p.id) { ids.insert(p.id) }
        }
        enabledIds = ids
        loadError = await store.loadError()?.localizedDescription
        notificationCenter.post(name: Self.commandsChangedNotification, object: nil)
    }

    /// 用户打开 Toggle（启用）→ 弹确认 gate（含权限 + automation 警告）。
    func prepareEnable(pluginId: String) {
        guard let plugin = plugins.first(where: { $0.id == pluginId }) else { return }
        pendingEnable = PluginEnableConfirmationGate(
            pluginId: pluginId, name: plugin.manifest.name,
            version: plugin.manifest.version, permissions: plugin.manifest.permissions
        )
    }

    /// 确认/取消启用。
    func confirmEnable(decision: PluginEnableDecision) async {
        guard let gate = pendingEnable else { return }
        defer { pendingEnable = nil }
        guard decision == .accepted else { return }  // 取消：不改 enabledIds（Toggle 自动回弹）
        do {
            try await store.confirm(pluginId: gate.pluginId, permissions: gate.permissions)
            enabledIds.insert(gate.pluginId)
            loadError = nil
            notificationCenter.post(name: Self.commandsChangedNotification, object: nil)
        } catch {
            loadError = String(localized: "无法保存插件权限：") + error.localizedDescription
        }
    }

    /// 用户关闭 Toggle（禁用）→ 直接 revoke（无危险，无需二次确认）。
    func disable(pluginId: String) async {
        do {
            try await store.revoke(pluginId: pluginId)
            enabledIds.remove(pluginId)
            loadError = nil
            notificationCenter.post(name: Self.commandsChangedNotification, object: nil)
        } catch {
            loadError = String(localized: "无法撤销插件权限：") + error.localizedDescription
        }
    }
}

// MARK: - Settings 插件 tab

/// Settings 中插件 tab 的内容（替换 P0/P2 placeholder）。列出已发现插件，每行
/// 名称 + 版本 + 权限 chips + 启用 Toggle。首次启用弹权限确认 sheet。
struct PluginSettingsSection: View {
    @Environment(AppDependencies.self) private var deps
    @State private var vm: PluginEnableViewModel?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                ProgressView()
            }
        }
        .task {
            let model = PluginEnableViewModel(
                registry: ScriptPluginRegistry(root: ScriptPluginRegistry.defaultRoot),
                store: deps.pluginPermissionStore
            )
            vm = model
            await model.load()
        }
    }

    @ViewBuilder
    private func content(vm: PluginEnableViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(localized: "Rail C 脚本插件")).font(.headline)
                Spacer()
                Button(String(localized: "重新扫描")) { Task { await vm.load() } }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            if let err = vm.loadError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            if vm.plugins.isEmpty {
                Text(String(localized: "未发现插件。将插件放入 ~/Library/Application Support/DevHub/plugins/<name>/（含 manifest.json）。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                List {
                    ForEach(vm.plugins) { plugin in
                        pluginRow(plugin, vm: vm)
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: Binding(
            get: { vm.pendingEnable },
            set: { vm.pendingEnable = $0 }
        )) { gate in
            PluginEnableConfirmationView(gate: gate) { decision in
                Task { await vm.confirmEnable(decision: decision) }
            }
        }
    }

    @ViewBuilder
    private func pluginRow(_ plugin: DiscoveredScriptPlugin, vm: PluginEnableViewModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(plugin.manifest.name).font(.body.weight(.semibold))
                    Text("v\(plugin.manifest.version)").font(.caption2).foregroundStyle(.secondary)
                }
                Text(plugin.id).font(.caption2).foregroundStyle(.tertiary)
                    .monospaced()
                // 权限 chips
                HStack(spacing: 4) {
                    ForEach(plugin.manifest.permissions, id: \.self) { perm in
                        Text(PluginEnableConfirmationGate.label(for: perm))
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(permissionColor(perm).opacity(0.15), in: Capsule())
                            .foregroundStyle(permissionColor(perm))
                    }
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { vm.enabledIds.contains(plugin.id) },
                set: { isOn in
                    if isOn {
                        vm.prepareEnable(pluginId: plugin.id)
                    } else {
                        Task { await vm.disable(pluginId: plugin.id) }
                    }
                }
            ))
            .labelsHidden()
            .accessibilityLabel(String(localized: "启用 \(plugin.manifest.name)"))
        }
        .padding(.vertical, 4)
    }

    private func permissionColor(_ p: ScriptPluginPermission) -> Color {
        switch p {
        case .automation: return .orange
        case .process:    return .orange
        case .network:    return .blue
        case .filesystem: return .secondary
        }
    }
}

/// 插件首次启用确认弹窗（仿 MCPConfirmationView）。
struct PluginEnableConfirmationView: View {
    let gate: PluginEnableConfirmationGate
    let onComplete: (PluginEnableDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "确认启用插件"))
                .font(.headline)
            Text(String(localized: "插件：\(gate.name)（\(gate.version)）"))
                .foregroundStyle(.secondary)
            Text(String(localized: "申请权限：\(gate.permissionSummary)"))
                .font(.system(.body, design: .monospaced))
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
        .accessibilityLabel(String(localized: "插件 \(gate.name) 启用确认"))
    }
}
