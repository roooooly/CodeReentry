import SwiftUI
import DevHubCore

/// 订阅新增/编辑表单（§5.4）。
struct SubscriptionFormView: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: SubscriptionSnapshot?
    let onSubmit: (SubscriptionInput) async throws -> Void

    @State private var name: String
    @State private var provider: String
    @State private var amountText: String
    @State private var currency: String
    @State private var cycle: SubscriptionCycle
    @State private var nextRenewal: Date
    @State private var reminderDaysBefore: Int
    @State private var notes: String
    @State private var isSaving = false
    @State private var submissionError: String?

    init(
        subscription: SubscriptionSnapshot? = nil,
        onSubmit: @escaping (SubscriptionInput) async throws -> Void
    ) {
        self.subscription = subscription
        self.onSubmit = onSubmit
        _name = State(initialValue: subscription?.name ?? "")
        _provider = State(initialValue: subscription?.provider ?? "")
        _amountText = State(initialValue: subscription.map { NSDecimalNumber(decimal: $0.amount).stringValue } ?? "")
        _currency = State(initialValue: subscription?.currency ?? "USD")
        _cycle = State(initialValue: subscription?.cycle ?? .monthly)
        _nextRenewal = State(initialValue: subscription?.nextRenewal ?? Date().addingTimeInterval(86400 * 30))
        _reminderDaysBefore = State(initialValue: subscription?.reminderDaysBefore ?? 3)
        _notes = State(initialValue: subscription?.notes ?? "")
    }

    private var currencies: [String] {
        Array(Set(["USD", "CNY", "EUR", "JPY", "GBP", "HKD", currency])).sorted()
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(subscription == nil ? String(localized: "添加订阅") : String(localized: "编辑订阅"))
                .font(.headline)
            Form {
                Section(String(localized: "基本信息")) {
                    TextField(String(localized: "名称"), text: $name)
                    TextField(String(localized: "提供方"), text: $provider)
                }
                Section(String(localized: "金额")) {
                    TextField(String(localized: "金额"), text: $amountText)
                    Picker(String(localized: "币种"), selection: $currency) {
                        ForEach(currencies, id: \.self) { Text($0).tag($0) }
                    }
                    Picker(String(localized: "周期"), selection: $cycle) {
                        Text(String(localized: "每月")).tag(SubscriptionCycle.monthly)
                        Text(String(localized: "每年")).tag(SubscriptionCycle.yearly)
                    }
                }
                Section(String(localized: "续费与提醒")) {
                    DatePicker(String(localized: "下次续费"), selection: $nextRenewal, displayedComponents: .date)
                    Stepper("\(reminderDaysBefore) " + String(localized: "天前提醒"), value: $reminderDaysBefore, in: 0...30)
                }
                Section(String(localized: "备注")) {
                    TextField(String(localized: "可选备注"), text: $notes, axis: .vertical)
                        .lineLimit(2...4)
                }
            }
            .formStyle(.grouped)

            if let submissionError {
                Label(submissionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .accessibilityLabel(String(localized: "保存失败：\(submissionError)"))
            }

            HStack {
                Button(String(localized: "取消"), role: .cancel) { dismiss() }
                    .disabled(isSaving)
                Spacer()
                Button {
                    Task { await submit() }
                } label: {
                    HStack(spacing: 6) {
                        if isSaving {
                            ProgressView().controlSize(.small)
                        }
                        Text(isSaving ? String(localized: "正在保存…") : String(localized: "保存"))
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid || isSaving)
                    .accessibilityLabel(String(localized: "保存订阅"))
            }
            .padding(.horizontal)
        }
        .padding(.top)
        .frame(width: 460, height: 520)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && Decimal(string: amountText).map { $0 >= 0 } == true
    }

    @MainActor
    private func submit() async {
        guard !isSaving else { return }
        guard let amount = Decimal(string: amountText) else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanProvider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = SubscriptionInput(
            name: cleanName,
            provider: cleanProvider.isEmpty ? cleanName : cleanProvider,
            amount: amount, currency: currency, cycle: cycle,
            nextRenewal: nextRenewal, reminderDaysBefore: reminderDaysBefore,
            notes: cleanNotes.isEmpty ? nil : cleanNotes,
            active: subscription?.active ?? true
        )
        isSaving = true
        submissionError = nil
        do {
            try await onSubmit(input)
            dismiss()
        } catch {
            // 保留所有字段，让用户可以原地修正或重试。
            submissionError = error.localizedDescription
            isSaving = false
        }
    }
}

enum SubscriptionFormSubmissionError: LocalizedError {
    case destinationUnavailable

    var errorDescription: String? {
        String(localized: "订阅页面已不可用，请关闭表单后重试。")
    }
}
