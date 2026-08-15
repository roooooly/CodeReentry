import SwiftUI
import Observation
import UniformTypeIdentifiers
import DevHubCore

@MainActor
@Observable
final class SubscriptionsTabViewModel {
    let projectId: UUID
    let store: SubscriptionStore
    let reminderScheduler: ReminderScheduler?
    var subscriptions: [SubscriptionSnapshot] = []
    var monthlyByCurrency: [String: Decimal] = [:]
    var yearlyByCurrency: [String: Decimal] = [:]
    var loadError: String?
    var operationError: String?
    /// CSV 导入结果（成功/失败提示）。非 nil 时弹 alert。
    var csvImportResult: String?

    init(projectId: UUID, store: SubscriptionStore, reminderScheduler: ReminderScheduler? = nil) {
        self.projectId = projectId
        self.store = store
        self.reminderScheduler = reminderScheduler
    }

    func load() async {
        do {
            subscriptions = try await store.listSnapshots(activeOnly: false, projectId: projectId)
            monthlyByCurrency = SubscriptionCalculator.monthlyTotalsByCurrency(subscriptions)
            yearlyByCurrency = SubscriptionCalculator.yearlyTotalsByCurrency(subscriptions)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    func delete(_ id: UUID) async {
        operationError = nil
        do {
            try await store.delete(id)
            reminderScheduler?.cancel(subscriptionId: id)
            await load()
        } catch {
            operationError = String(localized: "无法删除订阅：") + error.localizedDescription
        }
    }

    @discardableResult
    func create(_ input: SubscriptionInput) async throws -> UUID {
        operationError = nil
        var scopedInput = input
        scopedInput.projectId = projectId
        let id: UUID
        do {
            id = try await store.create(scopedInput)
        } catch {
            operationError = String(localized: "无法添加订阅：") + error.localizedDescription
            throw error
        }
        if input.active, let scheduler = reminderScheduler {
            do {
                try await scheduler.schedule(
                    subscriptionId: id, name: input.name,
                    renewal: input.nextRenewal, daysBefore: input.reminderDaysBefore
                )
            } catch {
                operationError = String(localized: "订阅已保存，但续费提醒创建失败：") + error.localizedDescription
            }
        }
        await load()
        return id
    }

    func update(_ id: UUID, with input: SubscriptionInput) async throws {
        operationError = nil
        var scopedInput = input
        scopedInput.projectId = projectId
        do {
            try await store.update(id, with: scopedInput)
        } catch {
            operationError = String(localized: "无法更新订阅：") + error.localizedDescription
            throw error
        }

        reminderScheduler?.cancel(subscriptionId: id)
        if scopedInput.active, let scheduler = reminderScheduler {
            do {
                try await scheduler.schedule(
                    subscriptionId: id, name: scopedInput.name,
                    renewal: scopedInput.nextRenewal, daysBefore: scopedInput.reminderDaysBefore
                )
            } catch {
                operationError = String(localized: "订阅已更新，但续费提醒创建失败：") + error.localizedDescription
            }
        }
        await load()
    }

    func setActive(_ subscription: SubscriptionSnapshot, active: Bool) async {
        let input = SubscriptionInput(
            name: subscription.name,
            provider: subscription.provider,
            amount: subscription.amount,
            currency: subscription.currency,
            cycle: subscription.cycle,
            nextRenewal: subscription.nextRenewal,
            reminderDaysBefore: subscription.reminderDaysBefore,
            notes: subscription.notes,
            projectId: projectId,
            active: active
        )
        do {
            try await update(subscription.id, with: input)
        } catch {
            // update 已设置可供 UI 展示的 operationError。
        }
    }

    /// 从 CSV 文本（Wallos 兼容）批量导入订阅。成功返回"已导入 N 条"，失败返回错误描述。
    func importCSV(_ csv: String) async {
        do {
            let rows = try SubscriptionCSVImporter.parse(csv)
            guard !rows.isEmpty else {
                csvImportResult = String(localized: "CSV 中没有可识别的订阅行。")
                return
            }
            try await store.importRows(rows, projectId: projectId, onScheduled: { [reminderScheduler] id, name, renewal in
                guard let scheduler = reminderScheduler else { return }
                try? await scheduler.schedule(
                    subscriptionId: id, name: name, renewal: renewal, daysBefore: 3
                )
            })
            await load()
            csvImportResult = String(localized: "已导入") + " \(rows.count) " + String(localized: "条订阅。")
        } catch {
            csvImportResult = String(localized: "CSV 解析失败：") + error.localizedDescription
                + "\n" + String(localized: "标准列：Name,Price,Currency,Cycle,Cycle_type,Next_payment,Active")
        }
    }
}

/// 项目详情中的订阅 tab（替换 P0 placeholder）。
struct SubscriptionsTab: View {
    let project: Project
    @State private var viewModel: SubscriptionsTabViewModel
    @State private var showingForm = false
    @State private var editingSubscription: SubscriptionSnapshot?
    @State private var showingCSVImporter = false
    @State private var pendingDeletion: SubscriptionSnapshot?

    init(
        project: Project,
        store: SubscriptionStore,
        reminderScheduler: ReminderScheduler? = nil,
        viewModel: SubscriptionsTabViewModel? = nil
    ) {
        self.project = project
        _viewModel = State(initialValue: viewModel ?? SubscriptionsTabViewModel(
            projectId: project.id,
            store: store,
            reminderScheduler: reminderScheduler
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
            Divider()
            subscriptionList
        }
        .task { await viewModel.load() }
        .sheet(isPresented: $showingForm) {
            SubscriptionFormView(subscription: editingSubscription) { input in
                let editingId = editingSubscription?.id
                if let editingId {
                    try await viewModel.update(editingId, with: input)
                } else {
                    _ = try await viewModel.create(input)
                }
            }
        }
        .fileImporter(
            isPresented: $showingCSVImporter,
            allowedContentTypes: [.commaSeparatedText]
        ) { result in
            switch result {
            case .success(let url):
                // fileImporter 返回安全域 URL，需 startAccessing
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url),
                      let csv = String(data: data, encoding: .utf8) else {
                    viewModel.csvImportResult = String(localized: "无法读取所选文件。")
                    return
                }
                Task { await viewModel.importCSV(csv) }
            case .failure:
                viewModel.csvImportResult = String(localized: "未选择文件。")
            }
        }
        .alert(String(localized: "CSV 导入"),
               isPresented: Binding(get: { viewModel.csvImportResult != nil },
                                    set: { if !$0 { viewModel.csvImportResult = nil } })) {
            Button(String(localized: "好")) { viewModel.csvImportResult = nil }
        } message: {
            Text(viewModel.csvImportResult ?? "")
        }
        .alert(String(localized: "订阅提示"),
               isPresented: Binding(get: { viewModel.operationError != nil },
                                    set: { if !$0 { viewModel.operationError = nil } })) {
            Button(String(localized: "好")) { viewModel.operationError = nil }
        } message: {
            Text(viewModel.operationError ?? "")
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
                Task { await viewModel.delete(subscription.id) }
            }
            Button(String(localized: "取消"), role: .cancel) {
                pendingDeletion = nil
            }
        } message: { subscription in
            Text(String(localized: "此操作会将“\(subscription.name)”标记为停用并取消续费提醒；历史记录仍会保留，之后可以恢复。"))
        }
    }

    private var summaryHeader: some View {
        SubscriptionSummaryHeader(
            monthlyByCurrency: viewModel.monthlyByCurrency,
            yearlyByCurrency: viewModel.yearlyByCurrency
        )
    }

    private var subscriptionList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if let loadError = viewModel.loadError {
                    HStack {
                        Label(loadError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                        Spacer()
                        Button(String(localized: "重试")) {
                            Task { await viewModel.load() }
                        }
                    }
                    .padding()
                    .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                if viewModel.subscriptions.isEmpty {
                    ContentUnavailableView {
                        Label(String(localized: "这个项目还没有订阅"), systemImage: "creditcard")
                    } description: {
                        Text(String(localized: "记录与项目直接相关的服务费用、续费日与提醒。"))
                    } actions: {
                        Button {
                            editingSubscription = nil
                            showingForm = true
                        } label: {
                            Label(String(localized: "添加订阅"), systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
                ForEach(viewModel.subscriptions, id: \.id) { sub in
                    SubscriptionRow(
                        sub: sub,
                        onEdit: {
                            editingSubscription = sub
                            showingForm = true
                        },
                        onToggleActive: {
                            Task { await viewModel.setActive(sub, active: !sub.active) }
                        },
                        onDelete: {
                            pendingDeletion = sub
                        }
                    )
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showingCSVImporter = true } label: {
                    Label(String(localized: "导入 CSV"), systemImage: "square.and.arrow.down")
                }
                .accessibilityLabel(String(localized: "从 CSV 文件导入订阅（Wallos 兼容格式）"))
                Button {
                    editingSubscription = nil
                    showingForm = true
                } label: {
                    Label(String(localized: "添加订阅"), systemImage: "plus")
                }
                .accessibilityLabel(String(localized: "添加订阅"))
            }
        }
    }

}

private struct SubscriptionSummaryHeader: View {
    let monthlyByCurrency: [String: Decimal]
    let yearlyByCurrency: [String: Decimal]

    private var currencies: [String] {
        monthlyByCurrency.keys.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "订阅汇总"))
                .font(.headline)
            if currencies.isEmpty {
                Text(String(localized: "暂无启用中的订阅。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 32) {
                    ForEach(currencies, id: \.self) { currency in
                        SubscriptionCurrencySummary(
                            currency: currency,
                            monthly: monthlyByCurrency[currency] ?? 0,
                            yearly: yearlyByCurrency[currency] ?? 0
                        )
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .accessibilityElement(children: .contain)
    }
}

private struct SubscriptionCurrencySummary: View {
    let currency: String
    let monthly: Decimal
    let yearly: Decimal

    private var accessibilitySummary: String {
        ListFormatter.localizedString(byJoining: [
            ProjectCardView.format(amount: monthly, currency: currency),
            ProjectCardView.formatAmount(amount: yearly, currency: currency) + String(localized: "/年")
        ])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(currency)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SubscriptionSummaryAmount(
                    amount: monthly,
                    currency: currency,
                    suffix: String(localized: "/月")
                )
                SubscriptionSummaryAmount(
                    amount: yearly,
                    currency: currency,
                    suffix: String(localized: "/年")
                )
            }
        }
        .accessibilityLabel(accessibilitySummary)
    }
}

private struct SubscriptionSummaryAmount: View {
    let amount: Decimal
    let currency: String
    let suffix: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(amount, format: .currency(code: currency))
                .font(.title3.bold())
            Text(suffix)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct SubscriptionRow: View {
    let sub: SubscriptionSnapshot
    let onEdit: () -> Void
    let onToggleActive: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sub.name).font(.body.weight(.semibold))
                Text(sub.provider).font(.caption).foregroundStyle(.secondary)
                if !sub.active {
                    Text(String(localized: "已停用"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                if let notes = sub.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(sub.amount, format: .currency(code: sub.currency))
                    .font(.body.monospacedDigit())
                Text(sub.cycle == .monthly ? String(localized: "每月") : String(localized: "每年"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(sub.nextRenewal, format: .dateTime.year().month().day())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(String(localized: "编辑 \(sub.name)"))
            Button(action: onToggleActive) {
                Image(systemName: sub.active ? "pause.circle" : "arrow.clockwise.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(
                sub.active
                    ? String(localized: "停用 \(sub.name)")
                    : String(localized: "恢复 \(sub.name)")
            )
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .accessibilityLabel(String(localized: "删除 \(sub.name)"))
        }
        .padding(.vertical, 6)
        .opacity(sub.active ? 1 : 0.65)
        .accessibilityElement(children: .contain)
    }
}
