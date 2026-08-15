import Foundation
import DevHubCore
@testable import DevHub

enum ProjectFixtures {
    /// 3 个置顶 + 2 个活跃 + 1 个归档，用于 snapshot/单元测试
    static func makeProjects() -> [Project] {
        [
            makeProject(name: "ExampleApp", path: "/Users/example/Projects/ExampleApp",
                        isPinned: true, group: nil, tags: ["ai"]),
            makeProject(name: "sample-workspace", path: "/Users/example/Projects/sample-workspace",
                        isPinned: true, group: nil, tags: []),
            makeProject(name: "developer-tools", path: "/Users/example/Projects/developer-tools",
                        isPinned: true, group: nil, tags: ["swift"]),
            makeProject(name: "web-client", path: "/Users/example/Projects/web-client",
                        isPinned: false, group: "Active", tags: []),
            makeProject(name: "api-service", path: "/Users/example/Projects/api-service",
                        isPinned: false, group: "Active", tags: []),
            makeProject(name: "archived-demo", path: "/Users/example/Projects/archived-demo",
                        isPinned: false, group: "Archive", tags: []),
        ]
    }

    static func makeProject(
        name: String, path: String, isPinned: Bool = false,
        group: String? = nil, tags: [String] = []
    ) -> Project {
        // Core 的 Project.init 不接收关系数组（@Relationship 默认 []）。
        Project(
            id: UUID(),
            stableId: UUID().uuidString,
            name: name,
            path: path,
            isPinned: isPinned,
            group: group,
            tags: tags
        )
    }
}
