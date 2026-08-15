import SwiftUI
import SwiftData
import Charts
import DevHubCore

/// 订阅用量与成本总览（§订阅用量与成本）。
///
/// 纯本地解析 Claude/Codex JSONL 的 token 用量 × 内置单价表，估算"等价 API 成本"。
/// 与固定订阅费（SubscriptionCalculator）合并展示总览。Codex 额外展示 5h/7d 额度。
struct UsageOverviewView: View {
    @Environment(AppDependencies.self) private var deps
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        ZStack {
            DevHubPaperBackground()
            Group {
                if deps.usageScanner.snapshot == nil {
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text(String(localized: "正在读取本地用量…"))
                            .font(.headline)
                        Text(String(localized: "首次统计会扫描 Claude Code 与 Codex 的本地记录；不会联网，也不会读取密钥。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 440)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            pageHeading
                            header
                            codexRateLimitCard
                            toolBreakdown
                            dailyChart
                            modelBreakdown
                            projectBreakdown
                        }
                        .padding(26)
                        .frame(maxWidth: 1180, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "用量与成本"))
        .task { await deps.usageScanner.refreshIfStale() }
        .toolbar {
            Button {
                Task { await deps.usageScanner.refresh() }
            } label: {
                Label(String(localized: "刷新"), systemImage: "arrow.clockwise")
            }
            .disabled(deps.usageScanner.isScanning)
        }
    }

    private var pageHeading: some View {
        HStack(alignment: .top) {
            DevHubSectionHeading(
                eyebrow: String(localized: "DEVHUB / USAGE"),
                title: String(localized: "用量与成本"),
                subtitle: String(localized: "把本地 token 记录换算成等价 API 成本；固定订阅仍单独列示。")
            )
            Spacer()
            if deps.usageScanner.isScanning {
                ProgressView()
                    .controlSize(.small)
            } else if let date = deps.usageScanner.lastScannedAt {
                Label {
                    HStack(spacing: 3) {
                        Text(String(localized: "更新于"))
                        Text(date, format: .dateTime.hour().minute())
                    }
                } icon: {
                    Image(systemName: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(String(localized: "最近更新时间"))
            }
        }
    }

    private var header: some View {
        let usageCost = deps.usageScanner.snapshot?.totalCostUSD ?? 0
        let subMonthly = monthlySubscriptionCost
        return HStack(alignment: .firstTextBaseline, spacing: 32) {
            VStack(alignment: .leading, spacing: 4) {
                Text(formatUSD(usageCost))
                    .font(.system(size: 34, weight: .bold))
                Text(String(localized: "估算 API 用量成本（全部历史）"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider().frame(height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(subMonthly.isEmpty ? "—" : subMonthly)
                    .font(.system(size: 20, weight: .semibold))
                Text(String(localized: "固定订阅月费"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .devHubSurface()
    }

    /// Codex 订阅额度（5h/7d 滚动窗口）。
    @ViewBuilder
    private var codexRateLimitCard: some View {
        if let limit = deps.usageScanner.codexRateLimit {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Codex 订阅额度"))
                    .font(.headline)
                rateBar(label: String(localized: "5 小时窗口"), percent: limit.primaryUsedPercent,
                        resetsAt: limit.primaryResetsAt)
                rateBar(label: String(localized: "7 天窗口"), percent: limit.secondaryUsedPercent,
                        resetsAt: limit.secondaryResetsAt)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .devHubSurface()
        }
    }

    private func rateBar(label: String, percent: Double, resetsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text(String(format: "%.0f%%", percent))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(rateColor(percent))
                if let resetsAt {
                    Text(String(localized: "重置于 \(resetsAt, format: .dateTime.month().day().hour().minute())"))
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            ProgressView(value: min(percent, 100), total: 100)
                .tint(rateColor(percent))
        }
    }

    private func rateColor(_ percent: Double) -> Color {
        switch percent {
        case ..<50: return .green
        case ..<80: return .yellow
        default: return .red
        }
    }

    /// 按工具的成本与 token 分解。
    @ViewBuilder
    private var toolBreakdown: some View {
        let perTool = deps.usageScanner.snapshot?.perTool ?? [:]
        if !perTool.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "按工具分解")).font(.headline)
                ForEach(perTool.sorted(by: { $0.value.costUSD > $1.value.costUSD }), id: \.key) { tool, usage in
                    breakdownRow(name: toolDisplayName(tool), cost: usage.costUSD,
                                 tokens: usage.totalTokens, shareOf: deps.usageScanner.snapshot?.totalCostUSD)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .devHubSurface()
        }
    }

    /// 按模型分解。
    @ViewBuilder
    private var modelBreakdown: some View {
        let perModel = deps.usageScanner.snapshot?.perModel ?? [:]
        let visibleModels = perModel.filter { $0.value.totalTokens > 0 || $0.value.costUSD > 0 }
        if !visibleModels.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "按模型分解")).font(.headline)
                ForEach(visibleModels.sorted(by: { $0.value.costUSD > $1.value.costUSD }), id: \.key) { model, usage in
                    breakdownRow(name: model, cost: usage.costUSD,
                                 tokens: usage.totalTokens, shareOf: deps.usageScanner.snapshot?.totalCostUSD)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .devHubSurface()
        }
    }

    /// 按项目分解（按 cwd 最长前缀归桶）。
    @ViewBuilder
    private var projectBreakdown: some View {
        let perProject = deps.usageScanner.snapshot?.perProject ?? [:]
        if !perProject.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "按项目分解")).font(.headline)
                ForEach(perProject.sorted(by: { $0.value.costUSD > $1.value.costUSD }), id: \.key) { path, usage in
                    breakdownRow(name: projectName(forPath: path), cost: usage.costUSD,
                                 tokens: usage.totalTokens, shareOf: deps.usageScanner.snapshot?.totalCostUSD)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .devHubSurface()
        }
    }

    /// 项目路径 → 显示名：优先用注册项目名，回退到路径末段。
    private func projectName(forPath path: String) -> String {
        let ctx = modelContext
        let pred = #Predicate<Project> { $0.path == path }
        let descriptor = FetchDescriptor<Project>(predicate: pred)
        if let project = (try? ctx.fetch(descriptor))?.first {
            return project.name
        }
        return (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
    }

    /// 最近 14 天每日成本柱状图。
    @ViewBuilder
    private var dailyChart: some View {
        let perDay = deps.usageScanner.snapshot?.perDay ?? [:]
        if !perDay.isEmpty {
            let days = last14DaysData(from: perDay)
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "最近 14 天成本趋势")).font(.headline)
                Chart(days) { item in
                    BarMark(
                        x: .value(String(localized: "日期"), item.dayShort),
                        y: .value("USD", item.cost.doubleValue)
                    )
                    .foregroundStyle(.tint)
                }
                .frame(height: 180)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .devHubSurface()
        }
    }

    private func breakdownRow(name: String, cost: Decimal, tokens: Int, shareOf: Decimal?) -> some View {
        let share: Double = {
            guard let total = shareOf, total > 0 else { return 0 }
            return NSDecimalNumber(decimal: cost / total).doubleValue
        }()
        return HStack {
            Text(name).font(.subheadline)
            Spacer()
            Text(formatUSD(cost)).font(.subheadline.weight(.semibold))
            Text("\(tokens) tok").font(.caption).foregroundStyle(.secondary)
            Text(String(format: "%.0f%%", share * 100))
                .font(.caption2).foregroundStyle(.tertiary)
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: - 辅助

    private struct DayCost: Identifiable { let id = UUID(); let dayShort: String; let cost: NSDecimalNumber }

    private func last14DaysData(from perDay: [String: UsageSnapshot.ToolUsage]) -> [DayCost] {
        let cal = Calendar(identifier: .gregorian)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"
        let displayFmt = DateFormatter()
        displayFmt.locale = Locale(identifier: "en_US_POSIX")
        displayFmt.dateFormat = "MM/dd"
        var result: [DayCost] = []
        for i in stride(from: 13, through: 0, by: -1) {
            let date = cal.date(byAdding: .day, value: -i, to: Date()) ?? Date()
            let key = fmt.string(from: date)
            let cost = perDay[key]?.costUSD ?? 0
            result.append(DayCost(dayShort: displayFmt.string(from: date), cost: NSDecimalNumber(decimal: cost)))
        }
        return result
    }

    private var monthlySubscriptionCost: String {
        let subs = (try? modelContext.fetch(FetchDescriptor<Subscription>())) ?? []
        let snapshots = subs.filter(\.active).map(SubscriptionSnapshot.init)
        let monthly = SubscriptionCalculator.monthlyTotalsByCurrency(snapshots)
        if monthly.count == 1, let (cur, amt) = monthly.first {
            return "\(ProjectCardView.format(amount: amt, currency: cur))"
        }
        return monthly.isEmpty ? "" : "\(monthly.count) " + String(localized: "种币种")
    }

    private func toolDisplayName(_ id: String) -> String {
        switch id {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        default: return id
        }
    }

    private func formatUSD(_ value: Decimal) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f.string(from: value as NSDecimalNumber) ?? "$\(value)"
    }
}
