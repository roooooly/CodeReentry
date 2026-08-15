import Testing
import Foundation
@testable import DevHubCore

@Suite("PathLocator")
struct PathLocatorTests {

    @Test("writes project.local.json with stableId on ensure")
    func writesStableId() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let stableId = try PathLocator.ensureDevHub(at: tmp, stableId: "anchor-123")
        #expect(stableId == "anchor-123")

        let jsonURL = tmp.appendingPathComponent(".devhub/project.local.json")
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))

        let data = try Data(contentsOf: jsonURL)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["stableId"] as? String == "anchor-123")
        #expect(parsed?["schemaVersion"] as? Int == 1)
    }

    @Test("idempotent: re-ensure returns existing stableId, does not overwrite")
    func idempotent() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        _ = try PathLocator.ensureDevHub(at: tmp, stableId: "first")
        let second = try PathLocator.ensureDevHub(at: tmp, stableId: "ignored-second")
        #expect(second == "first")
    }

    @Test("reads existing stableId from disk")
    func readExisting() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let devhub = tmp.appendingPathComponent(".devhub", isDirectory: true)
        try FileManager.default.createDirectory(at: devhub, withIntermediateDirectories: true)
        let json: [String: Any] = ["stableId": "preexisting", "schemaVersion": 1]
        try JSONSerialization.data(withJSONObject: json)
            .write(to: devhub.appendingPathComponent("project.local.json"))

        #expect(try PathLocator.readStableId(at: tmp) == "preexisting")
    }

    @Test("read returns nil when .devhub absent")
    func readAbsent() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        #expect(try PathLocator.readStableId(at: tmp) == nil)
    }
}
