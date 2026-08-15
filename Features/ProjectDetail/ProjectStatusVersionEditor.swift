import SwiftUI
import DevHubCore

/// 编辑项目生命周期状态与版本号的 sheet（§项目总览 详情头入口）。
struct ProjectStatusVersionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let project: Project
    var onSaved: () -> Void

    @State private var status: ProjectStatus
    @State private var version: String

    init(project: Project, onSaved: @escaping () -> Void) {
        self.project = project
        self.onSaved = onSaved
        _status = State(initialValue: project.statusEnum)
        _version = State(initialValue: project.versionString)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "项目状态与版本"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "状态"))
                    .font(.subheadline.weight(.medium))
                Picker(String(localized: "状态"), selection: $status) {
                    ForEach(ProjectStatus.allCases, id: \.self) { s in
                        Label(s.title, systemImage: s.systemImage).tag(s)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "版本号"))
                    .font(.subheadline.weight(.medium))
                TextField(String(localized: "如 1.2.0"), text: $version)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button(String(localized: "取消"), role: .cancel) { dismiss() }
                Button(String(localized: "保存")) { save() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 380)
        .accessibilityElement(children: .contain)
    }

    private func save() {
        project.statusEnum = status
        project.versionString = version.trimmingCharacters(in: .whitespacesAndNewlines)
        onSaved()
        dismiss()
    }
}
