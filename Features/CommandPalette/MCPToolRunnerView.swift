import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class MCPToolRunnerViewModel {
    let tool: MCPToolInfo
    var argumentsJSON = "{}"
    var result: MCPToolCallResult?
    var errorMessage: String?
    var isRunning = false
    var isConfirming = false

    private let caller: any MCPToolCalling

    init(tool: MCPToolInfo, caller: any MCPToolCalling) {
        self.tool = tool
        self.caller = caller
    }

    /// Validate before showing the security prompt. This is intentionally a
    /// separate step: opening the prompt must never invoke an external server.
    func requestExecution() {
        guard validatedArguments() != nil else { return }
        isConfirming = true
    }

    func cancelExecution() {
        isConfirming = false
    }

    func confirmExecution() async {
        guard !isRunning, let arguments = validatedArguments() else { return }
        isConfirming = false
        isRunning = true
        result = nil
        errorMessage = nil
        defer { isRunning = false }

        do {
            result = try await caller.callTool(
                serverName: tool.serverName,
                toolName: tool.name,
                argumentsJSON: arguments
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func validatedArguments() -> String? {
        let trimmed = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            argumentsJSON = "{}"
            return "{}"
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] else {
            errorMessage = String(localized: "工具参数必须是 JSON 对象。")
            isConfirming = false
            return nil
        }
        errorMessage = nil
        return trimmed
    }
}

struct MCPToolRunnerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: MCPToolRunnerViewModel

    init(tool: MCPToolInfo, caller: any MCPToolCalling) {
        _viewModel = State(initialValue: MCPToolRunnerViewModel(tool: tool, caller: caller))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.tool.title)
                        .font(.title3.weight(.semibold))
                    Text("\(viewModel.tool.serverName) / \(viewModel.tool.name)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer()
                Button(String(localized: "关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            if let description = viewModel.tool.description, !description.isEmpty {
                Text(description)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            DisclosureGroup(String(localized: "输入 Schema")) {
                ScrollView {
                    Text(viewModel.tool.inputSchemaJSON)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .frame(maxHeight: 130)
            }

            Text(String(localized: "参数 JSON"))
                .font(.headline)
            TextEditor(text: $viewModel.argumentsJSON)
                .font(.body.monospaced())
                .frame(minHeight: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
                .accessibilityIdentifier("mcp-tool-arguments")

            Label(
                String(localized: "MCP server 可能读写文件、访问网络或启动进程。CodeReentry 只会在你检查参数并再次确认后发起调用。"),
                systemImage: "exclamationmark.shield.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)

            if let result = viewModel.result {
                VStack(alignment: .leading, spacing: 6) {
                    Text(result.isError ? String(localized: "工具返回错误") : String(localized: "执行结果"))
                        .font(.headline)
                        .foregroundStyle(result.isError ? .red : .primary)
                    ScrollView {
                        Text(result.text.isEmpty ? String(localized: "工具没有返回文本内容。") : result.text)
                            .font(.caption.monospaced())
                            .foregroundStyle(result.isError ? .red : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                    .padding(8)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            HStack {
                if viewModel.isRunning {
                    ProgressView()
                        .controlSize(.small)
                    Text(String(localized: "正在调用…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(String(localized: "检查并执行…")) {
                    viewModel.requestExecution()
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isRunning)
                .accessibilityIdentifier("mcp-tool-run")
            }
        }
        .padding(20)
        .frame(width: 600)
        .frame(minHeight: 480)
        .alert(
            String(localized: "MCP 工具调用失败"),
            isPresented: Binding(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )
        ) {
            Button(String(localized: "好")) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .confirmationDialog(
            String(localized: "确认执行 MCP 工具"),
            isPresented: $viewModel.isConfirming,
            titleVisibility: .visible
        ) {
            Button(String(localized: "确认并执行")) {
                Task { await viewModel.confirmExecution() }
            }
            Button(String(localized: "取消"), role: .cancel) {
                viewModel.cancelExecution()
            }
        } message: {
            Text(String(localized: "将把上面的参数发送给 \(viewModel.tool.serverName) / \(viewModel.tool.name)。请仅在 server 来源和参数都可信时继续。"))
        }
    }
}
