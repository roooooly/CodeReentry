import Testing
import Foundation
@testable import DevHubCore

@Suite("KimiPathDiscovery")
struct KimiPathDiscoveryTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kimi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 在 fake home 下建出 kimi-desktop/kimi-agent/conversation-statuses.json 等结构。
    func createKimiFakeLayout(at home: URL, subdir: String = "kimi-desktop") throws {
        let userData = home.appendingPathComponent("Library/Application Support/\(subdir)")
        let agent = userData.appendingPathComponent("kimi-agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try #"{"sess_a":{"status":"done","model":"k1.5"}}"#.write(
            to: agent.appendingPathComponent("conversation-statuses.json"),
            atomically: true, encoding: .utf8)
        try #"{"sess_a":{"used":1024}}"#.write(
            to: agent.appendingPathComponent("conversation-context-usage.json"),
            atomically: true, encoding: .utf8)
    }

    @Test func discoverFindsExistingCandidate() async throws {
        let home = try makeTempDir()
        try createKimiFakeLayout(at: home)
        let candidates = KimiPathDiscovery.standardCandidates(home: home)
        let paths = KimiPathDiscovery.discover(candidates: candidates, home: home)
        #expect(paths != nil)
        #expect(paths?.appBundleId == "com.moonshot.kimichat")
        #expect(FileManager.default.fileExists(atPath: paths!.conversationStatuses.path))
    }

    @Test func discoverReturnsNilWhenAbsent() async throws {
        let home = try makeTempDir()
        let candidates = KimiPathDiscovery.standardCandidates(home: home)
        let paths = KimiPathDiscovery.discover(candidates: candidates, home: home)
        #expect(paths == nil)
    }

    @Test func discoverPicksKimiDesktopFirst() async throws {
        let home = try makeTempDir()
        try createKimiFakeLayout(at: home, subdir: "kimi-desktop")
        let candidates = KimiPathDiscovery.standardCandidates(home: home)
        let paths = KimiPathDiscovery.discover(candidates: candidates, home: home)
        #expect(paths?.userDataDir.lastPathComponent == "kimi-desktop")
    }

    @Test func logFilePathComputed() async throws {
        let home = try makeTempDir()
        try createKimiFakeLayout(at: home)
        let candidates = KimiPathDiscovery.standardCandidates(home: home)
        let paths = KimiPathDiscovery.discover(candidates: candidates, home: home)
        #expect(paths?.logFile.path.contains("Logs/kimi-desktop/main.log") == true)
    }
}

@Suite("KimiReader")
struct KimiReaderTests {

    func makeTempDir() throws -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("kimi-r-\(UUID().uuidString)", isDirectory: true)
            .also { try? FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
    }

    @Test func discoverFromStatusesJson() async throws {
        let home = try makeTempDir()
        let agent = home.appendingPathComponent("Library/Application Support/kimi-desktop/kimi-agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try #"{"sess_a":{"status":"done","model":"k1.5"},"sess_b":{"status":"active","model":"k1.5"}}"#.write(
            to: agent.appendingPathComponent("conversation-statuses.json"), atomically: true, encoding: .utf8)
        try #"{"sess_a":{"used":2048}}"#.write(
            to: agent.appendingPathComponent("conversation-context-usage.json"), atomically: true, encoding: .utf8)

        let paths = KimiPaths(
            appBundleId: "com.moonshot.kimichat",
            userDataDir: home.appendingPathComponent("Library/Application Support/kimi-desktop"),
            agentStateDir: agent,
            conversationStatuses: agent.appendingPathComponent("conversation-statuses.json"),
            conversationContextUsage: agent.appendingPathComponent("conversation-context-usage.json"),
            logFile: home.appendingPathComponent("main.log"), indexedDbDir: nil)
        let reader = KimiReader(paths: paths)
        let sessions = try await reader.discover()
        #expect(sessions.count == 2)
        let ids = Set(sessions.map(\.toolSessionId))
        #expect(ids == ["sess_a", "sess_b"])
        let a = sessions.first { $0.toolSessionId == "sess_a" }!
        #expect(a.preview.contains("k1.5"))
        #expect(a.preview.contains("2048"))  // token usage
    }

    @Test func discoverNoPathsReturnsEmpty() async throws {
        let reader = KimiReader(paths: nil)
        let sessions = try await reader.discover()
        #expect(sessions.isEmpty)
    }

    @Test func identityKeyIsKimiColonSessionId() async throws {
        let home = try makeTempDir()
        let agent = home.appendingPathComponent("Library/Application Support/kimi-desktop/kimi-agent")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try #"{"xyz":{}}"#.write(to: agent.appendingPathComponent("conversation-statuses.json"), atomically: true, encoding: .utf8)
        let paths = KimiPaths(
            appBundleId: "x", userDataDir: home, agentStateDir: agent,
            conversationStatuses: agent.appendingPathComponent("conversation-statuses.json"),
            conversationContextUsage: agent.appendingPathComponent("x.json"),
            logFile: home.appendingPathComponent("l"), indexedDbDir: nil)
        let sessions = try await KimiReader(paths: paths).discover()
        #expect(sessions.first?.identityKey == "kimi:xyz")
    }
}

// 临时小工具
private extension URL {
    func also(_ f: (URL) throws -> Void) -> URL { try? f(self); return self }
}
