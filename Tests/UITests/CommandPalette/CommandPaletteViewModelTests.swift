import Testing
import Foundation
import DevHubCore
@testable import DevHub

@Suite("CommandPaletteViewModel")
@MainActor
struct CommandPaletteViewModelTests {

    func makeVM(items: [CommandItem]) -> CommandPaletteViewModel {
        CommandPaletteViewModel(allItems: items)
    }

    @Test("empty query 列出全部")
    func emptyListsAll() {
        let vm = makeVM(items: [
            .openProject(name: "ExampleApp", stableId: "s1"),
            .switchTab(name: "Tools", tab: .tools)
        ])
        vm.query = ""
        vm.update()
        #expect(vm.results.count == 2)
    }

    @Test("详情 tab 命令只从启用列表生成")
    func enabledDetailTabsOnly() {
        let items = CommandItem.enabledDetailTabItems([.tools, .memory, .ops])

        #expect(items == [
            .switchTab(name: DetailTab.tools.title, tab: .tools),
            .switchTab(name: DetailTab.memory.title, tab: .memory),
            .switchTab(name: DetailTab.ops.title, tab: .ops)
        ])
    }

    @Test("query 'exa' 命中项目不命中 Tools")
    func filterProject() {
        let vm = makeVM(items: [
            .openProject(name: "ExampleApp", stableId: "s1"),
            .switchTab(name: "Tools", tab: .tools)
        ])
        vm.query = "exa"
        vm.update()
        #expect(vm.results.count == 1)
        if case .openProject = vm.results.first { } else { Issue.record("应命中 project") }
    }

    @Test("选中移动 selectedIndex 不越界")
    func moveSelection() {
        let vm = makeVM(items: [
            .openProject(name: "ExampleApp", stableId: "s1"),
            .openProject(name: "Bitshovel", stableId: "s2")
        ])
        vm.update()
        #expect(vm.selectedIndex == 0)
        vm.moveDown(); vm.moveDown()
        #expect(vm.selectedIndex == 1)
        vm.moveUp(); vm.moveUp()
        #expect(vm.selectedIndex == 0)
    }

    @Test("query 变化时 selectedIndex 归零")
    func resetSelectionOnQuery() {
        let vm = makeVM(items: [
            .openProject(name: "ExampleApp", stableId: "s1"),
            .openProject(name: "Bitshovel", stableId: "s2")
        ])
        vm.moveDown()
        vm.setQuery("bit")
        #expect(vm.selectedIndex == 0)
    }

    @Test("confirm 返回当前选中并触发回调")
    func confirm() {
        var executed: CommandItem?
        let vm = makeVM(items: [.openProject(name: "ExampleApp", stableId: "s1")])
        vm.onExecute = { executed = $0 }
        vm.confirm()
        #expect(executed != nil)
        if case .openProject(_, let sid) = executed { #expect(sid == "s1") } else { Issue.record() }
    }

    @Test("空结果 confirm 不触发回调")
    func confirmEmptyNoOp() {
        var executed = false
        let vm = makeVM(items: [.openProject(name: "ExampleApp", stableId: "s1")])
        vm.onExecute = { _ in executed = true }
        vm.setQuery("zzz")  // 无匹配
        vm.confirm()
        #expect(executed == false)
    }

    @Test("MCP ToolContribution 与运行时元数据共同生成命令")
    func mcpContributionBecomesCommand() throws {
        let tool = MCPToolInfo(
            serverName: "filesystem",
            name: "read_file",
            title: "读取文件",
            description: "Read a local file",
            inputSchemaJSON: #"{"type":"object"}"#
        )
        let contribution = ToolContribution(
            id: "mcp.filesystem.read_file",
            title: "read_file",
            sourcePluginId: "mcp.filesystem"
        )

        let item = try #require(MCPCommandCatalog.items(
            contributions: [contribution],
            toolInfos: [tool]
        ).first)

        #expect(item.id == "mcp-tool:filesystem.read_file")
        #expect(item.title == "读取文件 · filesystem")
        #expect(item.group == "MCP 工具")
        guard case .runMCPTool(_, let serverName, let toolName) = item else {
            Issue.record("应生成 MCP 工具命令")
            return
        }
        #expect(serverName == "filesystem")
        #expect(toolName == "read_file")
    }

    @Test("缺少贡献或 sourcePluginId 不匹配的 MCP 元数据不会进入命令面板")
    func mcpCatalogRejectsStaleOrSpoofedMetadata() {
        let tool = MCPToolInfo(
            serverName: "filesystem",
            name: "read_file",
            title: "Read",
            description: nil,
            inputSchemaJSON: "{}"
        )
        let spoofed = ToolContribution(
            id: "mcp.filesystem.read_file",
            title: "read_file",
            sourcePluginId: "mcp.other"
        )

        #expect(MCPCommandCatalog.items(contributions: [], toolInfos: [tool]).isEmpty)
        #expect(MCPCommandCatalog.items(contributions: [spoofed], toolInfos: [tool]).isEmpty)
    }
}
