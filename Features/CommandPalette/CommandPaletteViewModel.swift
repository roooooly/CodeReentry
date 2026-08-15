import Foundation
import SwiftUI
import DevHubCore

/// 命令面板中的可执行项（§7.2）。
enum CommandItem: Identifiable, Hashable, Sendable {
    case openProject(name: String, stableId: String)
    case switchTab(name: String, tab: DetailTab)
    case runPluginAction(name: String, pluginId: String, actionId: String)
    case runMCPTool(name: String, serverName: String, toolName: String)

    var id: String {
        switch self {
        case .openProject(_, let s):       "open-project:\(s)"
        case .switchTab(_, let t):          "switch-tab:\(t.rawValue)"
        case .runPluginAction(_, let p, let a): "plugin-action:\(p).\(a)"
        case .runMCPTool(_, let server, let tool): "mcp-tool:\(server).\(tool)"
        }
    }
    var title: String {
        switch self {
        case .openProject(let n, _):       n
        case .switchTab(let n, _):         n
        case .runPluginAction(let n, _, _): n
        case .runMCPTool(let n, _, _):      n
        }
    }
    var group: String {
        switch self {
        case .openProject:       String(localized: "项目")
        case .switchTab:         String(localized: "标签")
        case .runPluginAction:   String(localized: "插件")
        case .runMCPTool:        String(localized: "MCP 工具")
        }
    }

    static func enabledDetailTabItems(_ tabs: [DetailTab]) -> [CommandItem] {
        tabs.map { .switchTab(name: $0.title, tab: $0) }
    }
}

/// Joins the plugin contribution point with MCP's richer runtime metadata.
/// A tool is shown only when both views agree, so a stale contribution can
/// never open a runner with the wrong server or schema.
enum MCPCommandCatalog {
    static func items(
        contributions: [ToolContribution],
        toolInfos: [MCPToolInfo]
    ) -> [CommandItem] {
        let contributionsByID = Dictionary(
            contributions.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return toolInfos
            .filter { tool in
                guard let contribution = contributionsByID[contributionID(for: tool)] else {
                    return false
                }
                return contribution.sourcePluginId == "mcp.\(tool.serverName)"
            }
            .sorted {
                if $0.serverName == $1.serverName { return $0.title < $1.title }
                return $0.serverName < $1.serverName
            }
            .map {
                .runMCPTool(
                    name: "\($0.title) · \($0.serverName)",
                    serverName: $0.serverName,
                    toolName: $0.name
                )
            }
    }

    static func contributionID(for tool: MCPToolInfo) -> String {
        "mcp.\(tool.serverName).\(tool.name)"
    }
}

@MainActor
@Observable
final class CommandPaletteViewModel {
    let allItems: [CommandItem]
    var query = ""
    var results: [CommandItem] = []
    var selectedIndex = 0
    var onExecute: ((CommandItem) -> Void)?

    init(allItems: [CommandItem], onExecute: ((CommandItem) -> Void)? = nil) {
        self.allItems = allItems
        self.onExecute = onExecute
        update()
    }

    func update() {
        let ranked = FuzzyMatcher.rank(query: query, in: allItems, key: { $0.title })
        results = ranked.map { $0.item }
        if selectedIndex > results.count - 1 { selectedIndex = max(results.count - 1, 0) }
    }

    func setQuery(_ q: String) {
        query = q
        update()
        selectedIndex = 0
    }

    func moveDown() { selectedIndex = min(selectedIndex + 1, max(results.count - 1, 0)) }
    func moveUp() { selectedIndex = max(selectedIndex - 1, 0) }

    func confirm() {
        guard selectedIndex < results.count else { return }
        let item = results[selectedIndex]
        onExecute?(item)
    }
}
