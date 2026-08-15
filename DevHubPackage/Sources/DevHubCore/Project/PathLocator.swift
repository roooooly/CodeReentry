import Foundation

/// 管理 `.devhub/project.local.json`（§4.2 §4.3）。
/// **唯一**跟 git 同步的 stableId 锚点。memory/*.md 由 MemoryStore 处理（Task 35）。
public enum PathLocator {

    public static let schemaVersion = 1

    /// 确保 `.devhub/project.local.json` 存在。若已存在则**保留**原 stableId（跨机同步语义）。
    @discardableResult
    public static func ensureDevHub(at projectRoot: URL, stableId: String) throws -> String {
        let devhub = projectRoot.appendingPathComponent(".devhub", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: devhub.path) {
            try fm.createDirectory(at: devhub, withIntermediateDirectories: true)
        }
        let jsonURL = devhub.appendingPathComponent("project.local.json")
        if let existing = try? readStableId(at: projectRoot) {
            return existing
        }
        let payload: [String: Any] = [
            "stableId": stableId,
            "schemaVersion": schemaVersion,
            "createdAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: jsonURL, options: [.atomic])
        return stableId
    }

    public static func readStableId(at projectRoot: URL) throws -> String? {
        let jsonURL = projectRoot.appendingPathComponent(".devhub/project.local.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return nil }
        let data = try Data(contentsOf: jsonURL)
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parsed["stableId"] as? String
    }
}
