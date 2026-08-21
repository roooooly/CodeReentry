import Foundation

/// Marker for an isolated, fully synthetic performance profile.
/// The benchmark runner accepts only an empty initial session index, so a first scan
/// is measured on a clean store instead of a database fragmented by test-only deletes.
public struct PerformanceFixtureManifest: Codable, Equatable, Sendable {
    public static let schemaVersion = 2
    public static let fileName = "performance-fixture.json"

    public let schemaVersion: Int
    public let scale: String
    public let projectCount: Int
    public let sessionsPerProject: Int
    public let initialIndexState: String

    public init(
        scale: String,
        projectCount: Int,
        sessionsPerProject: Int,
        initialIndexState: String
    ) {
        self.schemaVersion = Self.schemaVersion
        self.scale = scale
        self.projectCount = projectCount
        self.sessionsPerProject = sessionsPerProject
        self.initialIndexState = initialIndexState
    }

    public var sessionCount: Int { projectCount * sessionsPerProject }
}
