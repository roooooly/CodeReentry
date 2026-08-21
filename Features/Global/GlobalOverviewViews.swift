import SwiftUI
import SwiftData
import Observation
import AppKit
import UniformTypeIdentifiers
import DevHubCore

@MainActor
@Observable
final class GlobalSubscriptionsViewModel {
    private let store: SubscriptionStore
    private let reminderScheduler: ReminderScheduler?
    private(set) var subscriptions: [SubscriptionSnapshot] = []
    private(set) var monthlyByCurrency: [String: Decimal] = [:]
    private(set) var yearlyByCurrency: [String: Decimal] = [:]
    var errorMessage: String?
    var operationMessage: String?

    init(store: SubscriptionStore, reminderScheduler: ReminderScheduler? = nil) {
        self.store = store
        self.reminderScheduler = reminderScheduler
    }

    func load() async {
        do {
            subscriptions = try await store.listSnapshots(activeOnly: false)
            monthlyByCurrency = SubscriptionCalculator.monthlyTotalsByCurrency(subscriptions)
            yearlyByCurrency = SubscriptionCalculator.yearlyTotalsByCurrency(subscriptions)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func create(_ input: SubscriptionInput) async throws -> UUID {
        operationMessage = nil
        var globalInput = input
        globalInput.projectId = nil
        let id = try await store.create(globalInput)
        var reminderWarning: String?
        do {
            try await scheduleIfNeeded(id: id, input: globalInput)
        } catch {
            reminderWarning = String(localized: "订阅已保存，但续费提醒创建失败：") + error.localizedDescription
        }
        await load()
        operationMessage = reminderWarning
        return id
    }

    func update(_ subscription: SubscriptionSnapshot, with input: SubscriptionInput) async throws {
        operationMessage = nil
        var scopedInput = input
        scopedInput.projectId = subscription.projectId
        try await store.update(subscription.id, with: scopedInput)
        reminderScheduler?.cancel(subscriptionId: subscription.id)
        var reminderWarning: String?
        do {
            try await scheduleIfNeeded(id: subscription.id, input: scopedInput)
        } catch {
            reminderWarning = String(localized: "订阅已更新，但续费提醒创建失败：") + error.localizedDescription
        }
        await load()
        operationMessage = reminderWarning
    }

    func setActive(_ subscription: SubscriptionSnapshot, active: Bool) async {
        var input = SubscriptionInput(snapshot: subscription)
        input.active = active
        do {
            try await update(subscription, with: input)
        } catch {
            operationMessage = String(localized: "无法更新订阅：") + error.localizedDescription
        }
    }

    func delete(_ subscription: SubscriptionSnapshot) async {
        do {
            try await store.delete(subscription.id)
            reminderScheduler?.cancel(subscriptionId: subscription.id)
            await load()
        } catch {
            operationMessage = String(localized: "无法删除订阅：") + error.localizedDescription
        }
    }

    func importCSV(_ csv: String) async -> String {
        do {
            let rows = try SubscriptionCSVImporter.parse(csv)
            guard !rows.isEmpty else { return String(localized: "CSV 中没有可识别的订阅行。") }
            try await store.importRows(rows, projectId: nil) { [reminderScheduler] id, name, renewal in
                try? await reminderScheduler?.schedule(
                    subscriptionId: id, name: name, renewal: renewal, daysBefore: 3
                )
            }
            await load()
            return String(localized: "已导入") + " \(rows.count) " + String(localized: "条全局订阅。")
        } catch {
            return String(localized: "CSV 解析失败：") + error.localizedDescription
        }
    }

    var renewalMonths: [SubscriptionRenewalMonth] {
        let active = subscriptions.filter(\.active).sorted { $0.nextRenewal < $1.nextRenewal }
        let grouped = Dictionary(grouping: active) { subscription in
            let components = Calendar.current.dateComponents([.year, .month], from: subscription.nextRenewal)
            return Calendar.current.date(from: components) ?? subscription.nextRenewal
        }
        return grouped.keys.sorted().map {
            SubscriptionRenewalMonth(month: $0, subscriptions: grouped[$0] ?? [])
        }
    }

    private func scheduleIfNeeded(id: UUID, input: SubscriptionInput) async throws {
        guard input.active, let reminderScheduler else { return }
        try await reminderScheduler.schedule(
            subscriptionId: id,
            name: input.name,
            renewal: input.nextRenewal,
            daysBefore: input.reminderDaysBefore
        )
    }
}

private extension SubscriptionInput {
    init(snapshot: SubscriptionSnapshot) {
        self.init(
            name: snapshot.name, provider: snapshot.provider, amount: snapshot.amount,
            currency: snapshot.currency, cycle: snapshot.cycle,
            nextRenewal: snapshot.nextRenewal,
            reminderDaysBefore: snapshot.reminderDaysBefore, notes: snapshot.notes,
            projectId: snapshot.projectId, active: snapshot.active
        )
    }
}

struct SubscriptionRenewalMonth: Identifiable, Equatable {
    let month: Date
    let subscriptions: [SubscriptionSnapshot]
    var id: Date { month }
}

struct GlobalSubscriptionsView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.modelContext) private var modelContext
    @State private var viewModel: GlobalSubscriptionsViewModel?
    @State private var showingForm = false
    @State private var editingSubscription: SubscriptionSnapshot?
    @State private var showingCSVImporter = false
    @State private var csvMessage: String?
    @State private var pendingDeletion: SubscriptionSnapshot?
    @State private var viewMode: ViewMode = .list

    private enum ViewMode: String, CaseIterable, Identifiable {
        case list, calendar
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let viewModel {
                if viewModel.subscriptions.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "尚无订阅"), systemImage: "creditcard")
                    } description: {
                        Text(String(localized: "添加固定费用与续费日，CodeReentry 会按币种汇总并在本机提醒。"))
                    } actions: {
                        Button {
                            editingSubscription = nil
                            showingForm = true
                        } label: {
                            Label(String(localized: "添加第一条订阅"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    if viewMode == .calendar {
                        renewalCalendar(viewModel)
                    } else {
                        List(viewModel.subscriptions) { subscription in
                            subscriptionRow(subscription, viewModel: viewModel)
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                    }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(String(localized: "订阅总览"))
        .task {
            let model = viewModel ?? GlobalSubscriptionsViewModel(
                store: deps.subscriptionStore,
                reminderScheduler: deps.reminderScheduler
            )
            viewModel = model
            await model.load()
        }
        .sheet(isPresented: $showingForm, onDismiss: { editingSubscription = nil }) {
            SubscriptionFormView(subscription: editingSubscription) { input in
                guard let viewModel else {
                    throw SubscriptionFormSubmissionError.destinationUnavailable
                }
                let editing = editingSubscription
                if let editing {
                    try await viewModel.update(editing, with: input)
                } else {
                    _ = try await viewModel.create(input)
                }
            }
        }
        .fileImporter(isPresented: $showingCSVImporter, allowedContentTypes: [.commaSeparatedText]) { result in
            guard case .success(let url) = result else { return }
            let didAccess = url.startAccessingSecurityScopedResource()
            defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
            guard let csv = try? String(contentsOf: url, encoding: .utf8) else {
                csvMessage = String(localized: "无法读取所选 CSV 文件。")
                return
            }
            Task { csvMessage = await viewModel?.importCSV(csv) }
        }
        .alert(
            String(localized: "订阅加载失败"),
            isPresented: Binding(
                get: { viewModel?.errorMessage != nil },
                set: { if !$0 { viewModel?.errorMessage = nil } }
            )
        ) {
            Button(String(localized: "好")) { viewModel?.errorMessage = nil }
        } message: {
            Text(viewModel?.errorMessage ?? "")
        }
        .alert(
            String(localized: "订阅提示"),
            isPresented: Binding(
                get: { viewModel?.operationMessage != nil },
                set: { if !$0 { viewModel?.operationMessage = nil } }
            )
        ) {
            Button(String(localized: "好")) { viewModel?.operationMessage = nil }
        } message: {
            Text(viewModel?.operationMessage ?? "")
        }
        .alert(String(localized: "CSV 导入"),
               isPresented: Binding(get: { csvMessage != nil }, set: { if !$0 { csvMessage = nil } })) {
            Button(String(localized: "好")) { csvMessage = nil }
        } message: {
            Text(csvMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "删除订阅？"),
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { subscription in
            Button(String(localized: "删除 \(subscription.name)"), role: .destructive) {
                pendingDeletion = nil
                Task { await viewModel?.delete(subscription) }
            }
            Button(String(localized: "取消"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: { subscription in
            Text(String(localized: "此操作会将“\(subscription.name)”标记为停用并取消续费提醒；历史记录仍会保留。"))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 24) {
                DevHubSectionHeading(
                    eyebrow: String(localized: "CODEREENTRY / SUBSCRIPTIONS"),
                    title: String(localized: "固定成本要看得见"),
                    subtitle: String(localized: "所有项目与全局订阅；不同币种保持分组，不做隐式换算。")
                )
                Spacer()
                if let viewModel {
                    ForEach(viewModel.monthlyByCurrency.keys.sorted(), id: \.self) { currency in
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(viewModel.monthlyByCurrency[currency] ?? 0, format: .currency(code: currency))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(DevHubTheme.ink)
                            Text(String(localized: "每月") + " · "
                                 + (viewModel.yearlyByCurrency[currency] ?? 0).formatted(.currency(code: currency))
                                 + String(localized: "/年"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let viewModel {
                DevHubCard(padding: 10) {
                    HStack(spacing: 10) {
                        Picker(String(localized: "显示方式"), selection: $viewMode) {
                            Label(String(localized: "列表"), systemImage: "list.bullet").tag(ViewMode.list)
                            Label(String(localized: "续费日历"), systemImage: "calendar").tag(ViewMode.calendar)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                        Spacer()
                        Button { Task { await viewModel.load() } } label: {
                            Label(String(localized: "刷新"), systemImage: "arrow.clockwise")
                        }
                        Button { showingCSVImporter = true } label: {
                            Label(String(localized: "导入 CSV"), systemImage: "square.and.arrow.down")
                        }
                        Button { exportCSV(viewModel.subscriptions) } label: {
                            Label(String(localized: "导出 CSV"), systemImage: "square.and.arrow.up")
                        }
                        Button {
                            editingSubscription = nil
                            showingForm = true
                        } label: {
                            Label(String(localized: "添加订阅"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 26)
        .padding(.bottom, 14)
        .frame(maxWidth: 1180)
    }

    private func subscriptionRow(
        _ subscription: SubscriptionSnapshot,
        viewModel: GlobalSubscriptionsViewModel
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(subscription.name).font(.body.weight(.medium))
                    if !subscription.active {
                        Text(String(localized: "已停用"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subscription.provider).font(.caption).foregroundStyle(.secondary)
                Text(projectName(for: subscription.projectId) ?? String(localized: "全局订阅"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(subscription.amount, format: .currency(code: subscription.currency))
                    .monospacedDigit()
                Text(String(localized: "下次续费：") + subscription.nextRenewal.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                editingSubscription = subscription
                showingForm = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "编辑 \(subscription.name)"))
            Button {
                Task { await viewModel.setActive(subscription, active: !subscription.active) }
            } label: {
                Image(systemName: subscription.active ? "pause.circle" : "arrow.clockwise.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                subscription.active
                    ? String(localized: "停用 \(subscription.name)")
                    : String(localized: "恢复 \(subscription.name)")
            )
        }
        .padding(.vertical, 3)
        .contextMenu {
            Button(String(localized: "编辑")) {
                editingSubscription = subscription
                showingForm = true
            }
            Button(String(localized: "删除（保留历史）"), role: .destructive) {
                pendingDeletion = subscription
            }
        }
    }

    private func renewalCalendar(_ viewModel: GlobalSubscriptionsViewModel) -> some View {
        List {
            ForEach(viewModel.renewalMonths) { group in
                Section(group.month.formatted(.dateTime.year().month(.wide))) {
                    ForEach(group.subscriptions) { subscription in
                        HStack {
                            Text(subscription.nextRenewal, format: .dateTime.day())
                                .font(.title3.monospacedDigit().bold())
                                .frame(width: 34)
                            VStack(alignment: .leading) {
                                Text(subscription.name)
                                Text(projectName(for: subscription.projectId) ?? String(localized: "全局订阅"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(subscription.amount, format: .currency(code: subscription.currency))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }

    private func exportCSV(_ subscriptions: [SubscriptionSnapshot]) {
        let panel = NSSavePanel()
        panel.title = String(localized: "导出订阅 CSV")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        panel.nameFieldStringValue = "devhub-subscriptions-\(formatter.string(from: Date())).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SubscriptionCSVExporter.export(subscriptions).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            viewModel?.errorMessage = error.localizedDescription
        }
    }

    private func projectName(for id: UUID?) -> String? {
        guard let id else { return nil }
        let descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first?.name
    }
}

@MainActor
@Observable
final class GlobalPlatformsViewModel {
    private let store: PlatformStore
    private(set) var accounts: [PlatformAccountSnapshot] = []
    var errorMessage: String?

    init(store: PlatformStore) { self.store = store }

    func load() async {
        do {
            accounts = try await store.allAccounts()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func open(_ account: PlatformAccountSnapshot) {
        guard let url = URL(string: account.loginUrl), url.scheme?.isEmpty == false else {
            errorMessage = String(localized: "登录地址无效。")
            return
        }
        guard let preset = PlatformPresets.preset(for: account.platform) else {
            errorMessage = String(localized: "未知平台类型。")
            return
        }
        switch preset.openKind {
        case .openUrl:
            if !NSWorkspace.shared.open(url) {
                errorMessage = String(localized: "无法打开登录地址。")
            }
        case .openApp(let appName):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-a", appName, account.loginUrl]
            do { try process.run() } catch { errorMessage = error.localizedDescription }
        }
    }
}

struct GlobalPlatformsView: View {
    @Environment(AppDependencies.self) private var deps
    @State private var viewModel: GlobalPlatformsViewModel?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DevHubSectionHeading(
                    eyebrow: String(localized: "CODEREENTRY / ACCOUNTS"),
                    title: String(localized: "平台账号"),
                    subtitle: String(localized: "集中查看账号并一键打开；编辑与项目绑定在项目“平台”页完成。")
                )
                Spacer()
                if let viewModel {
                    Button { Task { await viewModel.load() } } label: {
                        Label(String(localized: "刷新"), systemImage: "arrow.clockwise")
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .padding(.bottom, 14)
            .frame(maxWidth: 1180)
            if let viewModel {
                if viewModel.accounts.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "尚无平台账号"), systemImage: "globe")
                    } description: {
                        Text(String(localized: "先打开一个项目，在“平台”页添加账号并记录发布状态。"))
                    } actions: {
                        Button {
                            deps.selectedGlobalDestination = .projects
                        } label: {
                            Label(String(localized: "前往项目总览"), systemImage: "square.grid.2x2")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(viewModel.accounts, id: \.id) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.displayName).font(.body.weight(.medium))
                                Text(PlatformPresets.preset(for: account.platform)?.defaultDisplayName
                                     ?? account.platform.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(account.loginUrl)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button(String(localized: "打开")) { viewModel.open(account) }
                                .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 3)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle(String(localized: "平台账号"))
        .task {
            let model = viewModel ?? GlobalPlatformsViewModel(store: deps.platformStore)
            viewModel = model
            await model.load()
        }
        .alert(
            String(localized: "平台操作失败"),
            isPresented: Binding(
                get: { viewModel?.errorMessage != nil },
                set: { if !$0 { viewModel?.errorMessage = nil } }
            )
        ) {
            Button(String(localized: "好")) { viewModel?.errorMessage = nil }
        } message: {
            Text(viewModel?.errorMessage ?? "")
        }
    }
}
