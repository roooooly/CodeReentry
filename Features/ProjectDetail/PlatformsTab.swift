import SwiftUI
import Observation
import DevHubCore

// MARK: - Editable form state

struct PlatformAccountFormDraft: Equatable {
    var platform: Platform
    var displayName: String
    var loginUrl: String

    init(platform: Platform = .xiaohongshu, account: PlatformAccountSnapshot? = nil) {
        if let account {
            self.platform = account.platform
            self.displayName = account.displayName
            self.loginUrl = account.loginUrl
        } else {
            let preset = PlatformPresets.preset(for: platform)
            self.platform = platform
            self.displayName = preset?.defaultDisplayName ?? ""
            self.loginUrl = preset?.defaultLoginUrl ?? ""
        }
    }

    mutating func applyPresetChange(from oldPlatform: Platform, to newPlatform: Platform) {
        let oldPreset = PlatformPresets.preset(for: oldPlatform)
        let newPreset = PlatformPresets.preset(for: newPlatform)
        let shouldReplaceName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || displayName == oldPreset?.defaultDisplayName
        let shouldReplaceURL = loginUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || loginUrl == oldPreset?.defaultLoginUrl

        platform = newPlatform
        if shouldReplaceName { displayName = newPreset?.defaultDisplayName ?? "" }
        if shouldReplaceURL { loginUrl = newPreset?.defaultLoginUrl ?? "" }
    }

    var canSave: Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && URL(string: loginUrl.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.isEmpty == false
    }
}

struct PlatformBindingFormDraft: Equatable {
    var publishStatus: PublishStatus
    var publishUrl: String
    var publishNotes: String
    var hasLastPublishedAt: Bool
    var lastPublishedAt: Date

    init(binding: PlatformBindingSnapshot) {
        publishStatus = binding.publishStatus
        publishUrl = binding.publishUrl ?? ""
        publishNotes = binding.publishNotes ?? ""
        hasLastPublishedAt = binding.lastPublishedAt != nil
        lastPublishedAt = binding.lastPublishedAt ?? Date()
    }

    var publishURLIsValid: Bool {
        let value = publishUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || URL(string: value)?.scheme?.isEmpty == false
    }

    var update: PlatformBindingUpdate {
        PlatformBindingUpdate(
            publishStatus: publishStatus,
            publishUrl: publishUrl,
            publishNotes: publishNotes,
            lastPublishedAt: hasLastPublishedAt ? lastPublishedAt : nil
        )
    }
}

// MARK: - View model

@MainActor
@Observable
final class PlatformsTabViewModel {
    let store: PlatformStore
    let projectId: UUID
    var accounts: [PlatformAccountSnapshot] = []
    var bindings: [PlatformBindingSnapshot] = []
    var loadError: String?
    var saveError: String?

    init(store: PlatformStore, projectId: UUID) {
        self.store = store
        self.projectId = projectId
    }

    func load() async {
        do {
            accounts = try await store.allAccounts()
            bindings = try await store.bindings(projectId: projectId)
            loadError = nil
        } catch {
            loadError = String(localized: "平台数据加载失败：") + error.localizedDescription
        }
    }

    func addAccount(_ draft: PlatformAccountFormDraft) async throws {
        saveError = nil
        do {
            _ = try await store.createAccount(
                platform: draft.platform,
                displayName: draft.displayName,
                loginUrl: draft.loginUrl
            )
            await load()
        } catch {
            saveError = String(localized: "账号保存失败：") + error.localizedDescription
            throw error
        }
    }

    func updateAccount(id: UUID, draft: PlatformAccountFormDraft) async throws {
        saveError = nil
        do {
            try await store.updateAccount(
                id: id,
                platform: draft.platform,
                displayName: draft.displayName,
                loginUrl: draft.loginUrl
            )
            await load()
        } catch {
            saveError = String(localized: "账号更新失败：") + error.localizedDescription
            throw error
        }
    }

    func deleteAccount(id: UUID) async {
        saveError = nil
        do {
            try await store.deleteAccount(id: id)
            await load()
        } catch {
            saveError = String(localized: "账号删除失败：") + error.localizedDescription
        }
    }

    func bind(accountId: UUID, status: PublishStatus = .draft) async {
        saveError = nil
        do {
            _ = try await store.bind(projectId: projectId, accountId: accountId, status: status)
            await load()
        } catch {
            saveError = String(localized: "账号绑定失败：") + error.localizedDescription
        }
    }

    func updateBinding(id: UUID, draft: PlatformBindingFormDraft) async throws {
        saveError = nil
        do {
            try await store.updateBinding(id: id, update: draft.update)
            await load()
        } catch {
            saveError = String(localized: "发布信息保存失败：") + error.localizedDescription
            throw error
        }
    }

    func unbind(bindingId: UUID) async {
        saveError = nil
        do {
            try await store.deleteBinding(id: bindingId)
            await load()
        } catch {
            saveError = String(localized: "解绑失败：") + error.localizedDescription
        }
    }

    func openAccount(_ account: PlatformAccountSnapshot) {
        saveError = nil
        guard let preset = PlatformPresets.preset(for: account.platform),
              let url = URL(string: account.loginUrl),
              url.scheme?.isEmpty == false else {
            saveError = String(localized: "无法打开：登录地址无效。")
            return
        }

        switch preset.openKind {
        case .openUrl:
            if !NSWorkspace.shared.open(url) {
                saveError = String(localized: "无法打开登录地址，请检查默认浏览器设置。")
            }
        case .openApp(let appName):
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", appName, account.loginUrl]
            do {
                try task.run()
            } catch {
                saveError = String(localized: "无法打开") + " \(appName)：" + error.localizedDescription
            }
        }
    }
}

// MARK: - Project tab

/// 项目详情中的平台 tab。
struct PlatformsTab: View {
    let project: Project
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: PlatformsTabViewModel?
    @State private var accountEditor: AccountEditorContext?
    @State private var bindingEditor: BindingEditorContext?
    @State private var pendingDeletion: PlatformDeletionTarget?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let viewModel {
                platformContent(viewModel)
            } else {
                ProgressView(String(localized: "正在加载平台数据…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: project.id) {
            let model = PlatformsTabViewModel(store: deps.platformStore, projectId: project.id)
            viewModel = model
            await model.load()
        }
        .sheet(item: $accountEditor) { context in
            if let viewModel {
                PlatformAccountEditorView(account: context.account) { draft in
                    if let account = context.account {
                        try await viewModel.updateAccount(id: account.id, draft: draft)
                    } else {
                        try await viewModel.addAccount(draft)
                    }
                }
            }
        }
        .sheet(item: $bindingEditor) { context in
            if let viewModel {
                PlatformBindingEditorView(binding: context.binding) { draft in
                    try await viewModel.updateBinding(id: context.binding.id, draft: draft)
                }
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(deletionButtonTitle, role: .destructive) {
                guard let target = pendingDeletion else { return }
                pendingDeletion = nil
                Task {
                    switch target {
                    case .account(let account):
                        await viewModel?.deleteAccount(id: account.id)
                    case .binding(let binding):
                        await viewModel?.unbind(bindingId: binding.id)
                    }
                }
            }
            Button(String(localized: "取消"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text(deletionMessage)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "平台管理"))
                    .font(.headline)
                Text(String(localized: "集中管理账号，并记录当前项目的发布状态。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                accountEditor = AccountEditorContext(account: nil)
            } label: {
                Label(String(localized: "添加账号"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    @ViewBuilder
    private func platformContent(_ viewModel: PlatformsTabViewModel) -> some View {
        if viewModel.accounts.isEmpty,
           viewModel.loadError == nil,
           viewModel.saveError == nil {
            ContentUnavailableView {
                Label(String(localized: "尚无平台账号"), systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text(String(localized: "添加一次账号后，可在多个项目中复用，并分别记录发布状态。"))
            } actions: {
                Button {
                    accountEditor = AccountEditorContext(account: nil)
                } label: {
                    Label(String(localized: "添加第一个账号"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
            if viewModel.loadError != nil || viewModel.saveError != nil {
                Section {
                    if let error = viewModel.loadError {
                        errorRow(error, retry: { Task { await viewModel.load() } })
                    }
                    if let error = viewModel.saveError {
                        errorRow(error, retry: nil)
                    }
                }
            }

            Section(String(localized: "平台账号")) {
                ForEach(viewModel.accounts, id: \.id) { account in
                    accountRow(account, viewModel: viewModel)
                }
            }

            Section(String(localized: "本项目绑定")) {
                if viewModel.bindings.isEmpty {
                    Text(String(localized: "尚未绑定账号。请在上方账号列表中选择「绑定」。"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.bindings, id: \.id) { binding in
                        bindingRow(binding, viewModel: viewModel)
                    }
                }
            }
            }
            .listStyle(.inset)
        }
    }

    private func errorRow(_ message: String, retry: (() -> Void)?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
            Spacer()
            if let retry {
                Button(String(localized: "重试"), action: retry)
                    .buttonStyle(.borderless)
            }
        }
        .accessibilityLabel(message)
    }

    private func accountRow(
        _ account: PlatformAccountSnapshot,
        viewModel: PlatformsTabViewModel
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: account.platform))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName).font(.body.weight(.medium))
                Text(platformName(account.platform))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(account.loginUrl)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button(String(localized: "打开")) { viewModel.openAccount(account) }
                .buttonStyle(.bordered).controlSize(.small)
            Button(String(localized: "编辑")) {
                accountEditor = AccountEditorContext(account: account)
            }
            .buttonStyle(.bordered).controlSize(.small)
            Button(String(localized: "绑定")) {
                Task { await viewModel.bind(accountId: account.id) }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(viewModel.bindings.contains { $0.accountId == account.id })
            Button(role: .destructive) {
                pendingDeletion = .account(account)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help(String(localized: "删除账号"))
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(account.displayName)，\(platformName(account.platform))，\(account.loginUrl)")
    }

    private func bindingRow(
        _ binding: PlatformBindingSnapshot,
        viewModel: PlatformsTabViewModel
    ) -> some View {
        let account = viewModel.accounts.first { $0.id == binding.accountId }
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(account?.displayName ?? String(localized: "账号已删除"))
                        .font(.body.weight(.medium))
                    Text(statusName(binding.publishStatus))
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                if let url = binding.publishUrl, !url.isEmpty {
                    if let link = URL(string: url), link.scheme?.isEmpty == false {
                        Link(url, destination: link)
                            .font(.caption)
                            .lineLimit(1)
                    } else {
                        Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                if let notes = binding.publishNotes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let date = binding.lastPublishedAt {
                    Text(String(localized: "最后发布：") + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(String(localized: "编辑发布信息")) {
                bindingEditor = BindingEditorContext(binding: binding)
            }
            .buttonStyle(.bordered).controlSize(.small)
            Button(String(localized: "解绑"), role: .destructive) {
                pendingDeletion = .binding(binding)
            }
            .buttonStyle(.bordered).controlSize(.small)
        }
        .padding(.vertical, 3)
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .account: return String(localized: "删除平台账号？")
        case .binding: return String(localized: "解除项目绑定？")
        case nil: return String(localized: "确认删除？")
        }
    }

    private var deletionButtonTitle: String {
        switch pendingDeletion {
        case .account: return String(localized: "删除账号")
        case .binding: return String(localized: "解除绑定")
        case nil: return String(localized: "删除")
        }
    }

    private var deletionMessage: String {
        switch pendingDeletion {
        case .account(let account):
            return String(localized: "将删除账号「") + account.displayName
                + String(localized: "」及其所有项目绑定，此操作不可撤销。")
        case .binding:
            return String(localized: "只解除当前项目与账号的绑定，不会删除账号本身。")
        case nil:
            return ""
        }
    }

    private func platformName(_ platform: Platform) -> String {
        PlatformPresets.preset(for: platform)?.defaultDisplayName ?? platform.rawValue
    }

    private func statusName(_ status: PublishStatus) -> String {
        switch status {
        case .draft: return String(localized: "草稿")
        case .inReview: return String(localized: "审核中")
        case .published: return String(localized: "已发布")
        case .needsUpdate: return String(localized: "待更新")
        }
    }

    private func icon(for platform: Platform) -> String {
        switch platform {
        case .wechatMini, .wechatOA, .wechatDevTools: return "message.fill"
        case .twitter: return "bird.fill"
        case .xiaohongshu: return "book.fill"
        }
    }
}

// MARK: - Editor sheets

private struct AccountEditorContext: Identifiable {
    let id = UUID()
    let account: PlatformAccountSnapshot?
}

private struct BindingEditorContext: Identifiable {
    let id = UUID()
    let binding: PlatformBindingSnapshot
}

private enum PlatformDeletionTarget {
    case account(PlatformAccountSnapshot)
    case binding(PlatformBindingSnapshot)
}

private struct PlatformAccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlatformAccountFormDraft
    @State private var errorMessage: String?
    @State private var isSaving = false
    let isEditing: Bool
    let onSave: (PlatformAccountFormDraft) async throws -> Void

    init(
        account: PlatformAccountSnapshot?,
        onSave: @escaping (PlatformAccountFormDraft) async throws -> Void
    ) {
        _draft = State(initialValue: PlatformAccountFormDraft(account: account))
        isEditing = account != nil
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? String(localized: "编辑平台账号") : String(localized: "添加平台账号"))
                .font(.title2.weight(.semibold))

            Form {
                Picker(String(localized: "平台"), selection: $draft.platform) {
                    ForEach(Platform.allCases, id: \.self) { platform in
                        Text(PlatformPresets.preset(for: platform)?.defaultDisplayName ?? platform.rawValue)
                            .tag(platform)
                    }
                }
                .onChange(of: draft.platform) { oldValue, newValue in
                    draft.applyPresetChange(from: oldValue, to: newValue)
                }

                TextField(String(localized: "账号显示名"), text: $draft.displayName)
                TextField(String(localized: "登录 URL"), text: $draft.loginUrl)
                    .textContentType(.URL)
                Text(String(localized: "切换平台时，未修改的名称和 URL 会自动采用对应预置值。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button(String(localized: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? String(localized: "保存") : String(localized: "添加")) {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!draft.canSave || isSaving)
            }
        }
        .padding(20)
        .frame(width: 500, height: 360)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(draft)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}

private struct PlatformBindingEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PlatformBindingFormDraft
    @State private var errorMessage: String?
    @State private var isSaving = false
    let onSave: (PlatformBindingFormDraft) async throws -> Void

    init(
        binding: PlatformBindingSnapshot,
        onSave: @escaping (PlatformBindingFormDraft) async throws -> Void
    ) {
        _draft = State(initialValue: PlatformBindingFormDraft(binding: binding))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "编辑发布信息"))
                .font(.title2.weight(.semibold))

            Form {
                Picker(String(localized: "发布状态"), selection: $draft.publishStatus) {
                    Text(String(localized: "草稿")).tag(PublishStatus.draft)
                    Text(String(localized: "审核中")).tag(PublishStatus.inReview)
                    Text(String(localized: "已发布")).tag(PublishStatus.published)
                    Text(String(localized: "待更新")).tag(PublishStatus.needsUpdate)
                }
                .onChange(of: draft.publishStatus) { _, newValue in
                    if newValue == .published, !draft.hasLastPublishedAt {
                        draft.hasLastPublishedAt = true
                        draft.lastPublishedAt = Date()
                    }
                }

                TextField(String(localized: "发布 URL（可选）"), text: $draft.publishUrl)
                    .textContentType(.URL)
                if !draft.publishURLIsValid {
                    Text(String(localized: "请输入包含协议的 URL，例如 https://example.com。"))
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading) {
                    Text(String(localized: "发布备注"))
                    TextEditor(text: $draft.publishNotes)
                        .frame(minHeight: 80)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                }

                Toggle(String(localized: "记录最后发布时间"), isOn: $draft.hasLastPublishedAt)
                if draft.hasLastPublishedAt {
                    DatePicker(
                        String(localized: "最后发布时间"),
                        selection: $draft.lastPublishedAt,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button(String(localized: "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "保存")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.publishURLIsValid || isSaving)
            }
        }
        .padding(20)
        .frame(width: 540, height: 540)
    }

    private func save() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await onSave(draft)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isSaving = false
            }
        }
    }
}
