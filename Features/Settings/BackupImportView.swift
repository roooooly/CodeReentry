import SwiftUI
import UniformTypeIdentifiers
import DevHubCore

/// 备份导入对话框（§8.4）：选文件 → plan（路径重新定位）→ 缺失路径手动补全 → apply。
struct BackupImportView: View {
    let dependencies: AppDependencies
    @Binding var isPresented: Bool

    @State private var document: BackupDocument?
    @State private var report: ImportReport?
    @State private var manualPaths: [String: String] = [:]
    @State private var error: String?
    @State private var importing = false
    @State private var planning = false
    @State private var importMode: DataImportMode = .merge

    var body: some View {
        VStack(spacing: 16) {
            Text(String(localized: "导入备份")).font(.headline)

            if let document {
                documentSummary(document)
                Picker(String(localized: "导入方式"), selection: $importMode) {
                    Text(String(localized: "合并（保留现有数据）")).tag(DataImportMode.merge)
                    Text(String(localized: "替换（清除现有数据）")).tag(DataImportMode.replace)
                }
                .pickerStyle(.radioGroup)
                if importMode == .replace {
                    Label(
                        String(localized: "替换会清除当前项目、订阅、工具、平台与会话索引，再写入备份。Keychain 密钥不会被删除。"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } else {
                Button(String(localized: "选择备份文件…")) { pickFile() }
                    .buttonStyle(.borderedProminent)
            }

            if let report, !report.projectsPendingManual.isEmpty {
                missingPathsSection(report.projectsPendingManual)
            }

            if let error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button(String(localized: "取消"), role: .cancel) { isPresented = false }
                Spacer()
                if document != nil {
                    Button(String(localized: "导入")) { performImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(importing || planning || report == nil || hasUnresolvedPaths)
                }
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func documentSummary(_ doc: BackupDocument) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "已加载备份（v\(doc.schemaVersion)）")).font(.subheadline)
            Text("\(doc.projects.count) " + String(localized: "个项目"))
                .font(.caption).foregroundStyle(.secondary)
            Text("\(doc.subscriptions.count) " + String(localized: "个订阅"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func missingPathsSection(_ stableIds: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "以下项目路径未找到，请手动指定："))
                .font(.caption).foregroundStyle(.orange)
            ForEach(stableIds, id: \.self) { sid in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(sid).font(.caption.monospaced())
                        TextField(String(localized: "新路径"), text: Binding(
                            get: { manualPaths[sid] ?? "" },
                            set: { manualPaths[sid] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button(String(localized: "选择…")) { pickProjectDirectory(for: sid) }
                    }
                    if let validation = manualPathValidation(for: sid) {
                        Text(validation)
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasUnresolvedPaths: Bool {
        guard let report else { return false }
        return report.projectsPendingManual.contains { manualPathValidation(for: $0) != nil }
    }

    private func manualPathValidation(for stableId: String) -> String? {
        let raw = manualPaths[stableId]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return String(localized: "请选择项目目录。") }
        let path = (raw as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return String(localized: "路径不存在或不是文件夹。")
        }
        if let existing = try? PathLocator.readStableId(at: URL(fileURLWithPath: path)),
           existing != stableId {
            return String(localized: "该目录属于另一个项目（\(existing)）。")
        }
        return nil
    }

    private func pickProjectDirectory(for stableId: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "选择项目")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manualPaths[stableId] = url.path
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let doc = try BackupDocumentCodec.decode(data)
            document = doc
            report = nil
            manualPaths = [:]
            error = nil
            planning = true
            // 规划导入（异步）
            let deps = dependencies
            let roots = currentSearchRoots()
            Task {
                let importer = await DataImporter.make(modelContainer: deps.modelContainer,
                                                       pathRelocator: PathRelocator())
                do {
                    let r = try await importer.planImport(document: doc, searchRoots: roots)
                    await MainActor.run {
                        self.report = r
                        self.planning = false
                    }
                } catch {
                    await MainActor.run {
                        self.error = error.localizedDescription
                        self.planning = false
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func performImport() {
        guard let document, let report else {
            error = String(localized: "导入规划尚未完成，请稍后重试。")
            return
        }
        importing = true
        Task {
            do {
                let importer = await DataImporter.make(modelContainer: dependencies.modelContainer,
                                                       pathRelocator: PathRelocator())
                try await importer.applyImport(
                    document: document,
                    report: report,
                    manualPaths: manualPaths,
                    mode: importMode
                )
                // 导入后重建活跃订阅的本机通知。通知权限未授权时 scheduler
                // 会安全降级，其余恢复结果不受影响。
                let restoredSubscriptions = try await dependencies.subscriptionStore
                    .listSnapshots(activeOnly: true)
                for subscription in restoredSubscriptions {
                    try await dependencies.reminderScheduler.schedule(
                        subscriptionId: subscription.id,
                        name: subscription.name,
                        renewal: subscription.nextRenewal,
                        daysBefore: subscription.reminderDaysBefore
                    )
                }
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: Notification.Name("DevHubProjectsChanged"),
                        object: nil
                    )
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    importing = false
                }
            }
        }
    }

    private func currentSearchRoots() -> [String] {
        let context = dependencies.modelContainer.mainContext
        let configured = (try? dependencies.ensureAppSettings(in: context).projectsRoot)
            .map { ($0 as NSString).expandingTildeInPath }
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Projects", isDirectory: true).path
        return Array(Set([configured, fallback].compactMap { $0 })).sorted()
    }
}
