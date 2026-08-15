import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("Project model")
struct ProjectTests {

    @Test("init populates all fields with defaults")
    func initFields() throws {
        let id = UUID()
        let p = Project(
            id: id,
            stableId: "stable-abc",
            name: "ExampleApp",
            path: "/Users/example/Projects/ExampleApp"
        )
        #expect(p.id == id)
        #expect(p.stableId == "stable-abc")
        #expect(p.name == "ExampleApp")
        #expect(p.path == "/Users/example/Projects/ExampleApp")
        #expect(p.icon == nil)
        #expect(p.color == nil)
        #expect(p.isPinned == false)
        #expect(p.group == nil)
        #expect(p.tags == [])
        #expect(p.lastOpenedAt == nil)
        #expect(abs(p.createdAt.timeIntervalSinceNow) < 5)
        // 新增字段默认值（可选存储 + 计算属性）
        #expect(p.statusEnum == .active)
        #expect(p.versionString == "")
    }

    @Test("status/version round-trip and mutation")
    @MainActor
    func statusVersionRoundTrip() throws {
        let container = try ModelContainer(
            for: Project.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let p = Project(stableId: "s2", name: "P", path: "/tmp/P",
                        status: .completed, version: "1.2.0")
        #expect(p.statusEnum == .completed)
        #expect(p.versionString == "1.2.0")
        p.statusEnum = .paused
        p.versionString = "2.0.0-beta"
        ctx.insert(p)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Project>()).first!
        #expect(fetched.statusEnum == .paused)
        #expect(fetched.versionString == "2.0.0-beta")
    }

    @Test("tags can be mutated and persisted")
    @MainActor
    func tagsMutation() throws {
        let container = try ModelContainer(
            for: Project.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let p = Project(id: UUID(), stableId: "s1", name: "X", path: "/tmp/X")
        p.tags = ["web", "rust"]
        ctx.insert(p)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<Project>())
        #expect(fetched.count == 1)
        #expect(fetched[0].tags == ["web", "rust"])
    }

    @Test("stableId is the cross-machine identity anchor")
    func stableIdAnchorsIdentity() {
        let p1 = Project(id: UUID(), stableId: "same-stable", name: "ExampleApp", path: "/Users/example-a/ExampleApp")
        let p2 = Project(id: UUID(), stableId: "same-stable", name: "ExampleApp", path: "/Users/example-b/ExampleApp")
        #expect(p1.stableId == p2.stableId)
    }
}
