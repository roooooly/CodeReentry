import SwiftUI
import Observation
import DevHubCore

@MainActor
@Observable
final class OpsTabViewModel {
    let projectPath: URL
    let runner: LocalProcessRunner
    var meta: ProjectMeta?
    var scripts: [DetectedScript] = []
    var log: [LocalProcessRunner.LogLine] = []
    var search: String = ""
    var executing: Bool = false
    var pendingScript: DetectedScript?

    init(projectPath: URL, runner: LocalProcessRunner = LocalProcessRunner()) {
        self.projectPath = projectPath
        self.runner = runner
    }

    var filteredLog: [LocalProcessRunner.LogLine] {
        guard !search.isEmpty else { return log }
        return log.filter { $0.text.localizedCaseInsensitiveContains(search) }
    }

    func load() async {
        meta = try? await ProjectMetaReader.read(at: projectPath)
        scripts = (try? await ScriptDetector.detect(at: projectPath)) ?? []
    }

    /// 当前流式执行 task（用于停止）。
    private var executeTask: Task<Void, Never>?

    func requestExecution(of script: DetectedScript) {
        guard !executing else { return }
        pendingScript = script
    }

    func confirmExecution(of script: DetectedScript) {
        pendingScript = nil
        execute(script: script)
    }

    func cancelPendingExecution() {
        pendingScript = nil
    }

    func execute(script: DetectedScript) {
        guard !executing else { return }
        executing = true
        log.append(LocalProcessRunner.LogLine(stream: .system, text: "$ \(script.command)"))
        let cfg: LocalProcessRunner.LaunchConfig
        if let executable = script.executable {
            cfg = LocalProcessRunner.LaunchConfig(
                workingDir: projectPath,
                executable: executable,
                arguments: script.arguments
            )
        } else {
            // Procfile 的值本身就是用户选择执行的 shell 命令；其他探测源一律走安全 argv。
            cfg = LocalProcessRunner.LaunchConfig(
                workingDir: projectPath,
                command: script.command
            )
        }
        executeTask = Task { [weak self] in
            guard let self else { return }
            for await line in await self.runner.stream(cfg: cfg) {
                self.log.append(line)
            }
            self.executing = false
            self.executeTask = nil
        }
    }

    /// 停止当前流式执行。
    func stop() {
        guard executing || executeTask != nil else { return }
        executeTask?.cancel()
        executeTask = nil
        Task { await runner.terminateCurrent() }
        executing = false
        log.append(LocalProcessRunner.LogLine(stream: .system, text: String(localized: "[stopped] 用户中止")))
    }

    func clearLog() { log.removeAll() }
}

/// 项目详情中的运维 tab（替换 P0 placeholder）。
struct OpsTab: View {
    let project: Project
    @State private var viewModel: OpsTabViewModel?

    var body: some View {
        VStack(spacing: 0) {
            metaHeader
            Divider()
            HSplitView {
                scriptList
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: 430)
                logPanel
                    .frame(minWidth: 420, maxWidth: .infinity)
            }
        }
        .task {
            let path = URL(fileURLWithPath: project.path)
            let vm = OpsTabViewModel(projectPath: path)
            viewModel = vm
            await vm.load()
        }
        .onDisappear {
            // Ops ViewModel 随 tab/项目切换销毁；离开前终止其子进程，避免形成
            // 无 UI 可恢复、也无法停止的后台进程。
            viewModel?.stop()
        }
        .confirmationDialog(
            String(localized: "运行这个项目脚本？"),
            isPresented: Binding(
                get: { viewModel?.pendingScript != nil },
                set: { if !$0 { viewModel?.cancelPendingExecution() } }
            ),
            presenting: viewModel?.pendingScript
        ) { script in
            Button(String(localized: "运行“\(script.name)”")) {
                viewModel?.confirmExecution(of: script)
            }
            Button(String(localized: "取消"), role: .cancel) {
                viewModel?.cancelPendingExecution()
            }
        } message: { script in
            Text(String(localized: "CodeReentry 将在项目目录执行：\(script.command)"))
        }
    }

    private var metaHeader: some View {
        HStack {
            if let meta = viewModel?.meta {
                Label("\(meta.runtime) · \(meta.dependencyCount) " + String(localized: "个依赖"), systemImage: "doc.text")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(String(localized: "未识别运行时（无 package.json/Cargo.toml/go.mod/pyproject.toml）"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if viewModel?.executing == true {
                ProgressView().controlSize(.small)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
    }

    private var scriptList: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "可用脚本")).font(.headline)
                Text(String(localized: "从项目清单中检测；运行前会显示完整命令并再次确认。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if (viewModel?.scripts.isEmpty ?? true) {
                ContentUnavailableView(
                    String(localized: "未检测到可运行脚本"),
                    systemImage: "terminal",
                    description: Text(String(localized: "支持 package.json、Cargo、Go、Python 与 Procfile。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel?.scripts ?? [], id: \.id) { script in
                            HStack {
                                Text(script.name).font(.body.weight(.medium))
                                Text(script.source.rawValue).font(.caption2).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(.quaternary, in: Capsule())
                                Spacer()
                                if viewModel?.executing == true {
                                    Button(String(localized: "停止")) { viewModel?.stop() }
                                        .buttonStyle(.bordered).controlSize(.small)
                                        .tint(.red)
                                } else {
                                    Button(String(localized: "运行")) { viewModel?.requestExecution(of: script) }
                                        .buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
        .padding()
    }

    private var logPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(localized: "本地启动日志")).font(.headline)
                Spacer()
                TextField(String(localized: "搜索日志…"), text: Binding(
                    get: { viewModel?.search ?? "" },
                    set: { viewModel?.search = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                if !(viewModel?.log.isEmpty ?? true) {
                    Button(String(localized: "清空")) { viewModel?.clearLog() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            if viewModel?.log.isEmpty ?? true {
                ContentUnavailableView(
                    String(localized: "还没有运行日志"),
                    systemImage: "text.alignleft",
                    description: Text(String(localized: "从左侧选择脚本运行后，标准输出与错误会实时显示在这里。"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(viewModel?.filteredLog.map { formatLine($0) }.joined(separator: "\n") ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: .infinity)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding()
    }

    private func formatLine(_ line: LocalProcessRunner.LogLine) -> String {
        let prefix: String
        switch line.stream {
        case .stdout: prefix = ""
        case .stderr: prefix = "[err] "
        case .system: prefix = "[sys] "
        }
        return prefix + line.text
    }
}
