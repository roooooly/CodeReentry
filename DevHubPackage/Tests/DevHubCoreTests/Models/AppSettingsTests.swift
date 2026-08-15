import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("AppSettings model")
struct AppSettingsTests {

    @Test("singleton fixed id")
    func singletonId() {
        let s = AppSettings.singleton()
        #expect(s.id == AppSettings.singletonId)
    }

    @Test("defaults match spec §4.1")
    func defaults() {
        let s = AppSettings.singleton()
        #expect(s.projectsRoot == "~/Projects")
        #expect(s.theme == "system")
        #expect(s.sidebarWidth == 240)
        #expect(s.locale == "zh-CN")
        #expect(s.enabledPlugins == [])
    }

    @Test("fetchSingleton returns singleton or creates if missing")
    @MainActor
    func fetchSingleton() throws {
        let container = try ModelContainer(
            for: AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let first = try AppSettings.fetchOrCreate(in: ctx)
        let second = try AppSettings.fetchOrCreate(in: ctx)
        #expect(first.id == second.id)
        #expect(try ctx.fetch(FetchDescriptor<AppSettings>()).count == 1)
    }
}
