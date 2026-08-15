import SwiftUI
import AppKit
import DevHubCore

/// 一键安装执行器 + 流式日志视图（§工具管理）。
///
/// - `brew`/`npm`：用 `LocalProcessRunner.stream` 跑 `brew install`/`npm install -g`，实时显示输出。
/// - `manual`：直接用 NSWorkspace 打开下载页，不跑命令。
@MainActor
@Observable
final class InstallRunnerViewModel {
    let toolName: String
    let method: InstallMethod
    let installCommand: String?   // brew/npm 后半段，如 "install -g opencode-ai"
    let downloadURL: String?
    let runner: LocalProcessRunner
    var log: [LocalProcessRunner.LogLine] = []
    var running = false
    var finishedSuccessfully = false

    init(toolName: String, method: InstallMethod,
         installCommand: String?, downloadURL: String?,
         runner: LocalProcessRunner = LocalProcessRunner()) {
        self.toolName = toolName
        self.method = method
        self.installCommand = installCommand
        self.downloadURL = downloadURL
        self.runner = runner
    }

    /// 启动安装（manual 方式直接打开下载页并标记完成）。
    func start() async {
        switch method {
        case .manual:
            openDownloadPage()
            finishedSuccessfully = true
            return
        case .brew, .npm:
            await runShellInstall()
        }
    }

    private func runShellInstall() async {
        guard let cmd = installCommand, !cmd.isEmpty, running == false else { return }
        let executable = method == .brew ? "brew" : "npm"
        let args = ConfiguredCommand.tokenizeSafe(cmd)
        running = true
        log.append(LocalProcessRunner.LogLine(stream: .system, text: "$ \(executable) \(cmd)"))
        let cfg = LocalProcessRunner.LaunchConfig(
            workingDir: FileManager.default.homeDirectoryForCurrentUser,
            executable: executable, arguments: args, timeout: 600
        )
        for await line in await runner.stream(cfg: cfg) {
            log.append(line)
        }
        running = false
        // 末尾 system 行形如 "[exit 0]"
        if let last = log.last, last.stream == .system, last.text.contains("[exit 0]") {
            finishedSuccessfully = true
        }
    }

    func stop() async {
        running = false
        await runner.terminateCurrent()
        log.append(LocalProcessRunner.LogLine(stream: .system, text: String(localized: "[stopped] 用户中止")))
    }

    private func openDownloadPage() {
        guard let urlStr = downloadURL, let url = URL(string: urlStr) else { return }
        NSWorkspace.shared.open(url)
        log.append(LocalProcessRunner.LogLine(stream: .system, text: String(localized: "已打开下载页：\(urlStr)")))
    }

    var formattedLog: String {
        log.map { line -> String in
            let prefix: String
            switch line.stream {
            case .stdout: prefix = ""
            case .stderr: prefix = "[err] "
            case .system: prefix = "[sys] "
            }
            return prefix + line.text
        }.joined(separator: "\n")
    }
}

/// 安装 sheet 视图。
struct InstallRunnerView: View {
    @Environment(\.dismiss) private var dismiss
    @State var viewModel: InstallRunnerViewModel
    var onCompleted: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: viewModel.method == .manual ? "arrow.up.right.square" : "arrow.down.circle")
                    .foregroundStyle(.orange)
                Text(String(localized: "安装 \(viewModel.toolName)"))
                    .font(.headline)
                Spacer()
                if viewModel.method != .manual {
                    Text(methodLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if viewModel.method == .manual {
                Text(String(localized: "此工具需手动下载安装。已为你打开官方下载页，安装完成后回到此处点「已完成安装」。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(viewModel.formattedLog.isEmpty ? String(localized: "（等待输出）") : viewModel.formattedLog)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                if viewModel.running {
                    Button(String(localized: "停止"), role: .destructive) {
                        Task { await viewModel.stop() }
                    }
                }
                if viewModel.finishedSuccessfully {
                    Button(String(localized: "已完成安装，刷新")) {
                        onCompleted()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(viewModel.finishedSuccessfully ? String(localized: "关闭") : String(localized: "取消")) {
                    dismiss()
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            if viewModel.log.isEmpty { await viewModel.start() }
        }
    }

    private var methodLabel: String {
        switch viewModel.method {
        case .brew: return "Homebrew"
        case .npm:  return "npm"
        case .manual: return ""
        }
    }
}

/// 便利：给 ConfiguredCommand.tokenize 加一个不抛错的版本（安装命令由内置数据驱动，理论不会错）。
private extension ConfiguredCommand {
    static func tokenizeSafe(_ command: String) -> [String] {
        (try? tokenize(command)) ?? command.split(separator: " ").map(String.init)
    }
}
