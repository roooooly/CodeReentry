import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("ProjectRegistry")
struct ProjectRegistryTests {

    @MainActor
    private func makeRegistry() throws -> (ProjectRegistry, ModelContext) {
        let container = try ModelContainerFactory.makeContainer(inMemory: true)
        let ctx = ModelContext(container)
        return (ProjectRegistry(modelContext: ctx), ctx)
    }

    private func makeProjectDirectory(_ name: String = UUID().uuidString) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-project-registry-tests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("register adds a project")
    @MainActor
    func register() throws {
        let (reg, ctx) = try makeRegistry()
        let dir = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try reg.register(name: "ExampleApp", path: dir.path, stableId: "stable-example")
        try ctx.save()
        #expect(p.name == "ExampleApp")
        #expect(p.path == dir.path)
        #expect(p.stableId == "stable-example")
        #expect(try reg.list().count == 1)
        #expect(try PathLocator.readStableId(at: dir) == "stable-example")
    }

    @Test("unregister removes project but nullifies bindings")
    @MainActor
    func unregister() throws {
        let (reg, ctx) = try makeRegistry()
        let dir = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try reg.register(name: "X", path: dir.path, stableId: "sx")
        try ctx.save()
        try reg.unregister(id: p.id)
        try ctx.save()
        #expect(try reg.list().count == 0)
    }

    @Test("update tags")
    @MainActor
    func tags() throws {
        let (reg, _) = try makeRegistry()
        let dir = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try reg.register(name: "Y", path: dir.path, stableId: "sy")
        try reg.updateTags(id: p.id, tags: ["web", "rust"])
        #expect(try reg.list().first?.tags == ["web", "rust"])
    }

    @Test("setPinned toggles")
    @MainActor
    func pin() throws {
        let (reg, _) = try makeRegistry()
        let dir = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try reg.register(name: "Z", path: dir.path, stableId: "sz")
        try reg.setPinned(id: p.id, pinned: true)
        #expect(try reg.list().first?.isPinned == true)
    }

    @Test("setGroup assigns group")
    @MainActor
    func group() throws {
        let (reg, _) = try makeRegistry()
        let dir = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try reg.register(name: "W", path: dir.path, stableId: "sw")
        try reg.setGroup(id: p.id, group: "frontend")
        #expect(try reg.list().first?.group == "frontend")
    }

    @Test("updateOrganization saves group and tags together")
    @MainActor
    func organization() throws {
        let (reg, _) = try makeRegistry()
        let dir = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try reg.register(name: "Organized", path: dir.path, stableId: "organized")

        try reg.updateOrganization(id: p.id, group: "客户端", tags: ["swift", "macOS"])

        let saved = try #require(reg.list().first)
        #expect(saved.group == "客户端")
        #expect(saved.tags == ["swift", "macOS"])
    }

    @Test("markOpened records the supplied date")
    @MainActor
    func markOpened() throws {
        let (reg, _) = try makeRegistry()
        let dir = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = try reg.register(name: "Recent", path: dir.path, stableId: "recent")
        let openedAt = Date(timeIntervalSince1970: 1_722_222_222)

        try reg.markOpened(id: p.id, at: openedAt)

        #expect(try reg.list().first?.lastOpenedAt == openedAt)
    }

    @Test("register rejects duplicate path")
    @MainActor
    func duplicatePath() throws {
        let (reg, _) = try makeRegistry()
        let dir = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try reg.register(name: "A", path: dir.path, stableId: "s1")
        #expect(throws: ProjectRegistryError.duplicatePath) {
            _ = try reg.register(name: "B", path: dir.path, stableId: "s2")
        }
    }

    @Test("register reuses stableId already present in project.local.json")
    @MainActor
    func reusesStableId() throws {
        let (reg, _) = try makeRegistry()
        let dir = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try PathLocator.ensureDevHub(at: dir, stableId: "existing-stable")

        let project = try reg.register(name: "Moved", path: dir.path, stableId: "new-random")

        #expect(project.stableId == "existing-stable")
    }

    @Test("register rejects a missing directory without creating it")
    @MainActor
    func rejectsMissingPath() throws {
        let (reg, _) = try makeRegistry()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-missing-\(UUID().uuidString)")

        #expect(throws: ProjectRegistryError.invalidPath) {
            _ = try reg.register(name: "Missing", path: missing.path, stableId: "stable")
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test("relocate updates a missing project's path and preserves its stableId")
    @MainActor
    func relocateMissingProject() throws {
        let (reg, ctx) = try makeRegistry()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-old-\(UUID().uuidString)")
        let target = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: target) }
        let project = Project(stableId: "moved-stable", name: "Moved", path: missing.path)
        ctx.insert(project)
        try ctx.save()

        try reg.relocate(id: project.id, to: target.path)

        #expect(project.path == (target.path as NSString).standardizingPath)
        #expect(project.stableId == "moved-stable")
        #expect(try PathLocator.readStableId(at: target) == "moved-stable")
    }

    @Test("relocate rejects a folder anchored to a different project")
    @MainActor
    func relocateRejectsStableIdMismatch() throws {
        let (reg, ctx) = try makeRegistry()
        let target = try makeProjectDirectory()
        defer { try? FileManager.default.removeItem(at: target) }
        _ = try PathLocator.ensureDevHub(at: target, stableId: "other-stable")
        let project = Project(
            stableId: "expected-stable",
            name: "Moved",
            path: "/missing/moved"
        )
        ctx.insert(project)
        try ctx.save()

        #expect(throws: ProjectRegistryError.stableIdMismatch(
            expected: "expected-stable",
            found: "other-stable"
        )) {
            try reg.relocate(id: project.id, to: target.path)
        }
        #expect(project.path == "/missing/moved")
    }
}
