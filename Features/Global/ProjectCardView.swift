import SwiftUI
import DevHubCore

/// 单个项目卡片的纯展示数据。解耦自 SwiftData @Model，便于快照测试与列表渲染。
struct ProjectCardData: Identifiable, Equatable {
    struct ResumeTarget: Equatable {
        let tool: String
        let sessionId: String
        let cwd: String
        let title: String
    }

    let id: UUID
    let stableId: String
    let name: String
    let icon: String?
    let colorHex: String?
    let status: ProjectStatus
    let version: String
    let pathAvailable: Bool
    let toolCount: Int
    let sessionCount: Int
    /// 月度订阅成本（按币种），如 ["USD": 20, "CNY": 68]。
    let monthlyCostByCurrency: [String: Decimal]
    /// 最近一次会话时间（用于"最近活动"），nil 表示无会话。
    let lastActivityAt: Date?
    /// 最近一条可恢复会话；总览可直接继续工作，不必先进入详情页。
    let latestSession: ResumeTarget?

    init(
        id: UUID, stableId: String, name: String,
        icon: String?, colorHex: String?,
        status: ProjectStatus, version: String,
        pathAvailable: Bool,
        toolCount: Int, sessionCount: Int,
        monthlyCostByCurrency: [String: Decimal],
        lastActivityAt: Date?,
        latestSession: ResumeTarget? = nil
    ) {
        self.id = id
        self.stableId = stableId
        self.name = name
        self.icon = icon
        self.colorHex = colorHex
        self.status = status
        self.version = version
        self.pathAvailable = pathAvailable
        self.toolCount = toolCount
        self.sessionCount = sessionCount
        self.monthlyCostByCurrency = monthlyCostByCurrency
        self.lastActivityAt = lastActivityAt
        self.latestSession = latestSession
    }
}

/// 项目总览的卡片视图（§项目总览）。视觉语言复用 ToolCard：
/// `cornerRadius: 10` + `.padding()` + `.quaternary.opacity(0.4)` 背景 + Capsule 徽章。
struct ProjectCardView: View {
    let data: ProjectCardData
    var onTap: () -> Void = {}
    var onChangeStatus: () -> Void = {}
    var onContinueLatest: (() -> Void)?
    @State private var isHovering = false

    var body: some View {
        DevHubCard(padding: 0) {
            VStack(alignment: .leading, spacing: 13) {
                header
                metaRow
                Divider().overlay(DevHubTheme.divider)
                statsRow
                footerRow
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(data.pathAvailable ? iconColor : Color.orange)
                .frame(width: 3)
                .padding(.vertical, 14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isHovering ? DevHubTheme.accent.opacity(0.34) : .clear, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(isHovering ? 0.055 : 0), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            iconBlock
            VStack(alignment: .leading, spacing: 4) {
                Text(data.name)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(DevHubTheme.ink)
                    .lineLimit(1)
                if !data.version.isEmpty {
                    Text("v\(data.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            StatusBadge(status: data.status)
        }
    }

    private var iconBlock: some View {
        let symbol = data.icon?.isEmpty == false ? data.icon! : "folder.fill"
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(iconColor.opacity(0.11))
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(iconColor)
        }
        .frame(width: 38, height: 38)
        .accessibilityHidden(true)
    }

    private var iconColor: Color {
        if let hex = data.colorHex,
           let c = Color(hex: hex) {
            return c
        }
        return .accentColor
    }

    private var metaRow: some View {
        HStack(spacing: 12) {
            if !data.pathAvailable {
                Label(String(localized: "路径失效"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let last = data.lastActivityAt {
                Label(Self.relativeFormatter.localizedString(for: last, relativeTo: Date()),
                      systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                onChangeStatus()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(String(localized: "编辑状态与版本"))
        }
    }

    private var statsRow: some View {
        HStack(spacing: 10) {
            stat(value: "\(data.toolCount)", label: String(localized: "工具"),
                 systemImage: "wrench.and.screwdriver")
            stat(value: "\(data.sessionCount)", label: String(localized: "会话"),
                 systemImage: "bubble.left.and.bubble.right")
            if let cost = formattedMonthlyCost {
                stat(value: cost, label: String(localized: "月费"),
                     systemImage: "creditcard")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var footerRow: some View {
        HStack {
            if let latest = data.latestSession, let onContinueLatest {
                Button(action: onContinueLatest) {
                    Label(String(localized: "继续最近会话"), systemImage: "arrow.uturn.forward")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(DevHubTheme.accent)
                .help(String(localized: "用 \(latest.tool) 继续“\(latest.title)”"))
            }
            Spacer()
            Button(action: onTap) {
                Label(String(localized: "打开项目"), systemImage: "arrow.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.caption.weight(.medium))
        }
    }

    private func stat(value: String, label: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(DevHubTheme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(DevHubTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(label).font(.caption2)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(DevHubTheme.subtleFill.opacity(0.72), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 多币种月费：若只有一种币种显示单一值，多种则显示「N 种币种」。
    private var formattedMonthlyCost: String? {
        guard !data.monthlyCostByCurrency.isEmpty else { return nil }
        if data.monthlyCostByCurrency.count == 1,
           let (cur, amt) = data.monthlyCostByCurrency.first {
            return Self.format(amount: amt, currency: cur)
        }
        let total = data.monthlyCostByCurrency.values.reduce(Decimal.zero, +)
        return Self.format(amount: total, currency: data.monthlyCostByCurrency.keys.first ?? "")
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func formatAmount(amount: Decimal, currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        let value = f.string(from: amount as NSDecimalNumber) ?? "\(amount)"
        return "\(value) \(currency)"
    }

    static func format(amount: Decimal, currency: String) -> String {
        formatAmount(amount: amount, currency: currency) + String(localized: "/月")
    }

    private var accessibilityLabel: String {
        var parts = [String(localized: "项目卡片 \(data.name)")]
        parts.append(data.status.title)
        if !data.version.isEmpty { parts.append(String(localized: "版本 \(data.version)")) }
        parts.append(String(localized: "工具 \(data.toolCount) 个"))
        parts.append(String(localized: "会话 \(data.sessionCount) 条"))
        if !data.pathAvailable { parts.append(String(localized: "项目路径已失效")) }
        return ListFormatter.localizedString(byJoining: parts)
    }
}

extension Color {
    /// 解析 `#RRGGBB` / `RRGGBB` hex 色值，失败返回 nil。
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v & 0xFF0000) >> 16) / 255.0
        let g = Double((v & 0x00FF00) >> 8) / 255.0
        let b = Double(v & 0x0000FF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
