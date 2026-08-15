import Testing
import Foundation
@testable import DevHubCore

@Suite("Plugin System (Rail A 骨架)")
struct PluginSystemTests {

    @Test("PluginManifest 基本字段")
    func manifestFields() {
        let m = PluginManifest(name: "MCP", version: "1.0.0", rail: .mcp, permissions: [.process])
        #expect(m.name == "MCP")
        #expect(m.rail == .mcp)
        #expect(m.permissions == [.process])
        #expect(m.minAppVersion == nil)
    }

    @Test("ToolContribution Identifiable")
    func toolContributionId() {
        let t = ToolContribution(id: "mcp.fs.read", title: "Read File", sourcePluginId: "mcp")
        #expect(t.id == "mcp.fs.read")
        #expect(t.subtitle == nil)
    }

    @Test("ContributionRegistry 注册 + merge")
    func registryRegisterAndMerge() async {
        var r1 = ContributionRegistry()
        r1.register(tool: ToolContribution(id: "a", title: "A", sourcePluginId: "p1"))
        r1.register(action: ActionContribution(id: "x", title: "X", scope: .project, sourcePluginId: "p1"))

        var r2 = ContributionRegistry()
        r2.register(tool: ToolContribution(id: "b", title: "B", sourcePluginId: "p2"))

        let merged = ContributionRegistry.merge([r1, r2])
        #expect(merged.tools.count == 2)
        #expect(merged.actions.count == 1)
        #expect(merged.tools.map(\.id).sorted() == ["a", "b"])
    }

    @Test("DevHubPlugin 协议可被实现并 contribute")
    func pluginContributes() async {
        let plugin = TestPlugin()
        var registry = ContributionRegistry()
        await plugin.contribute(to: &registry)
        #expect(plugin.id == "test-plugin")
        #expect(plugin.manifest.rail == .builtin)
        #expect(registry.tools.count == 1)
        #expect(registry.tools.first?.title == "Test Tool")
    }

    @Test("Permission 全 4 种")
    func permissionCases() {
        #expect(Permission.allCases.count == 4)
        #expect(Permission.allCases.contains(.automation))
    }
}

private struct TestPlugin: DevHubPlugin {
    let id = "test-plugin"
    let manifest = PluginManifest(name: "Test", version: "0.1", rail: .builtin)
    func contribute(to registry: inout ContributionRegistry) async {
        registry.register(tool: ToolContribution(id: "test.tool", title: "Test Tool", sourcePluginId: id))
    }
}
