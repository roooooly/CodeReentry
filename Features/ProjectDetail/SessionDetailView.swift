import SwiftUI
import AppKit
import DevHubCore

/// Value-only metadata keeps detail sheets independent from a long-lived
/// SwiftData model graph. Global session lists can therefore render hundreds of
/// rows without pinning every managed object in the main context.
struct SessionDetailMetadata: Equatable {
    let tool: String
    let toolSessionId: String
    let startedAt: Date
    let messageCount: Int
    let title: String?
    let preview: String

    init(
        tool: String,
        toolSessionId: String,
        startedAt: Date,
        messageCount: Int,
        title: String?,
        preview: String
    ) {
        self.tool = tool
        self.toolSessionId = toolSessionId
        self.startedAt = startedAt
        self.messageCount = messageCount
        self.title = title
        self.preview = preview
    }

    init(session: SessionIndex) {
        self.init(
            tool: session.tool,
            toolSessionId: session.toolSessionId,
            startedAt: session.startedAt,
            messageCount: session.messageCount,
            title: session.title,
            preview: session.preview
        )
    }
}

/// 会话正文查看器 ViewModel（§会话管理 正文查看）。
@MainActor
@Observable
final class SessionDetailViewModel {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded(SessionDetail)
        case failed(String)
        case noReader
        case unreadable(String)   // 工具不支持读取正文（如 Kimi）
    }

    let session: SessionDetailMetadata
    let reader: (any SessionReader)?
    private(set) var state: LoadState = .idle

    init(session: SessionIndex, reader: (any SessionReader)?) {
        self.session = SessionDetailMetadata(session: session)
        self.reader = reader
    }

    init(session: SessionDetailMetadata, reader: (any SessionReader)?) {
        self.session = session
        self.reader = reader
    }

    func load() async {
        guard let reader else {
            // Kimi 等无内容 reader：给出明确提示而非通用错误
            state = .unreadable(String(localized: "此工具的会话正文暂不支持在 CodeReentry 内读取。可点「在原应用中打开」查看。"))
            return
        }
        state = .loading
        do {
            let detail = try await reader.load(session.toolSessionId)
            state = .loaded(detail)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var messages: [SessionMessage] {
        if case .loaded(let detail) = state { return detail.messages }
        return []
    }

    var isTruncated: Bool {
        if case .loaded(let detail) = state { return detail.isTruncated }
        return false
    }
}

/// 会话正文查看 sheet（§会话管理 正文查看）。
/// 展示完整对话消息，user/assistant 气泡分色，顶部元数据，支持滚动与文本选择。
struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @State var viewModel: SessionDetailViewModel
    var onOpenOriginal: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: 760, height: 620)
        .task { await viewModel.load() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    SessionDisplayText.displayTitle(
                        title: viewModel.session.title,
                        preview: viewModel.session.preview
                    ) ?? String(localized: "未命名会话")
                )
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Label(viewModel.session.tool, systemImage: "wrench.and.screwdriver")
                    Label(
                        viewModel.session.messageCount < 0
                            ? String(localized: "消息数未统计")
                            : "\(viewModel.session.messageCount) " + String(localized: "条消息"),
                        systemImage: "bubble.left.and.bubble.right"
                    )
                    Text(viewModel.session.startedAt, format: .dateTime.year().month().day().hour().minute())
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if let onOpenOriginal {
                Button(action: onOpenOriginal) {
                    Label(String(localized: "在原工具中继续"), systemImage: "arrow.uturn.forward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "关闭"))
        }
        .padding()
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle, .loading:
            ProgressView(String(localized: "正在读取会话正文…"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            messageList
        case .failed(let msg):
            ContentUnavailableView(
                String(localized: "无法读取会话"),
                systemImage: "exclamationmark.triangle",
                description: Text(msg)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noReader:
            ContentUnavailableView(
                String(localized: "无法读取会话"),
                systemImage: "questionmark.circle",
                description: Text(String(localized: "未找到此工具的会话读取器。"))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unreadable(let msg):
            ContentUnavailableView(
                String(localized: "暂不支持读取"),
                systemImage: "lock.doc",
                description: Text(msg)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if viewModel.isTruncated {
                        Label(
                            String(localized: "会话过大，仅显示受限范围内的内容；完整记录仍可在原工具或源文件中查看。"),
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                    ForEach(Array(viewModel.messages.enumerated()), id: \.offset) { index, msg in
                        MessageBubble(message: msg)
                            .id(index)
                    }
                }
                .padding()
            }
            .background(.quaternary.opacity(0.15))
        }
    }
}

/// 单条消息气泡。user 右对齐蓝底，assistant 左对齐灰底并渲染 markdown。
struct MessageBubble: View {
    let message: SessionMessage
    @State private var isToolExpanded = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(roleLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                contentBody
                Text(message.timestamp, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// 工具调用用可折叠块；其余角色用普通气泡。
    @ViewBuilder
    private var contentBody: some View {
        if message.role == .tool {
            DisclosureGroup(isExpanded: $isToolExpanded) {
                Text(message.toolInput ?? message.content)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            } label: {
                Label(message.toolName ?? String(localized: "工具调用"), systemImage: "wrench")
                    .font(.callout)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.orange.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 10)
            )
        } else {
            Group {
                if message.role == .assistant {
                    Text(LocalizedStringKey(message.content))
                        .textSelection(.enabled)
                } else {
                    Text(message.content)
                        .textSelection(.enabled)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                message.role == .user
                    ? Color.accentColor.opacity(0.12)
                    : Color.secondary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    private var accessibilityText: String {
        if message.role == .tool {
            let name = message.toolName ?? String(localized: "工具调用")
            return "\(roleLabel)，\(name)，\(message.content.prefix(120))"
        }
        return "\(roleLabel)，\(message.content.prefix(120))"
    }

    private var roleLabel: String {
        switch message.role {
        case .user: return String(localized: "用户")
        case .assistant: return String(localized: "助手")
        case .system: return String(localized: "系统")
        case .tool: return String(localized: "工具")
        }
    }
}
