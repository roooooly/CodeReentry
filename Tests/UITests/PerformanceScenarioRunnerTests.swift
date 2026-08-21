import Testing
import Foundation
@testable import DevHub

@Suite("Performance scenario configuration")
struct PerformanceScenarioRunnerTests {
    @Test("scenario is disabled without the explicit opt-in")
    func disabledByDefault() {
        #expect(PerformanceScenarioConfiguration(environment: [:]) == nil)
        #expect(PerformanceScenarioConfiguration(environment: [
            "DEVHUB_PERFORMANCE_PROFILE": "/tmp/profile"
        ]) == nil)
    }

    @Test("valid isolated configuration parses bounded cycles and recovery")
    func validConfiguration() throws {
        let configuration = try #require(PerformanceScenarioConfiguration(environment: [
            "DEVHUB_PERFORMANCE_SCENARIO": "1",
            "DEVHUB_PERFORMANCE_PROFILE": "/tmp/synthetic-profile",
            "DEVHUB_PERFORMANCE_CYCLES": "10",
            "DEVHUB_PERFORMANCE_IDLE_SECONDS": "300",
            "DEVHUB_PERFORMANCE_RECOVERY_SECONDS": "15"
        ]))

        #expect(configuration.profile.path == "/tmp/synthetic-profile")
        #expect(configuration.cycles == 10)
        #expect(configuration.idleSeconds == 300)
        #expect(configuration.recoverySeconds == 15)
    }

    @Test("invalid or excessive scenario bounds are rejected")
    func invalidBounds() {
        let base = [
            "DEVHUB_PERFORMANCE_SCENARIO": "1",
            "DEVHUB_PERFORMANCE_PROFILE": "/tmp/synthetic-profile"
        ]
        #expect(PerformanceScenarioConfiguration(environment: base.merging([
            "DEVHUB_PERFORMANCE_CYCLES": "0"
        ]) { _, new in new }) == nil)
        #expect(PerformanceScenarioConfiguration(environment: base.merging([
            "DEVHUB_PERFORMANCE_CYCLES": "101"
        ]) { _, new in new }) == nil)
        #expect(PerformanceScenarioConfiguration(environment: base.merging([
            "DEVHUB_PERFORMANCE_IDLE_SECONDS": "601"
        ]) { _, new in new }) == nil)
        #expect(PerformanceScenarioConfiguration(environment: base.merging([
            "DEVHUB_PERFORMANCE_RECOVERY_SECONDS": "301"
        ]) { _, new in new }) == nil)
    }
}
