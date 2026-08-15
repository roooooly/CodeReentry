import SwiftUI

struct CommandPaletteView: View {
    @State var viewModel: CommandPaletteViewModel
    let onCancel: () -> Void
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(String(localized: "搜索项目、标签、插件或 MCP 工具…"), text: Binding(
                get: { viewModel.query },
                set: { viewModel.setQuery($0) }
            ))
            .textFieldStyle(.roundedBorder)
            .padding(16)
            .focused($queryFocused)
            .onSubmit { viewModel.confirm() }
            .accessibilityIdentifier("palette-query")
            .accessibilityLabel(String(localized: "命令面板搜索框"))

            Divider()

            if viewModel.results.isEmpty {
                Text(String(localized: "无匹配项"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: Binding(
                    get: { viewModel.selectedIndex },
                    set: { if let v = $0 { viewModel.selectedIndex = v } }
                )) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) { idx, item in
                        HStack {
                            Text(item.title)
                            Spacer()
                            Text(item.group).foregroundStyle(.secondary).font(.caption)
                        }
                        .tag(idx)
                        .listRowBackground(
                            idx == viewModel.selectedIndex
                                ? Color.accentColor.opacity(0.2) : Color.clear
                        )
                        .accessibilityLabel("\(item.group) \(item.title)")
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 500, height: 360)
        .background(.regularMaterial)
        .onKeyPress(.upArrow) { viewModel.moveUp(); return .handled }
        .onKeyPress(.downArrow) { viewModel.moveDown(); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
        .task { queryFocused = true }
    }
}
