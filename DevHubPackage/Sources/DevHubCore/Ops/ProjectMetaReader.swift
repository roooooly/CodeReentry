import Foundation

public struct ProjectMeta: Equatable, Sendable {
    public let runtime: String          // "node" / "rust" / "go" / "python"
    public let dependencyCount: Int
    public let manifestFile: String     // "package.json" / "Cargo.toml" ...

    public init(runtime: String, dependencyCount: Int, manifestFile: String) {
        self.runtime = runtime; self.dependencyCount = dependencyCount; self.manifestFile = manifestFile
    }
}

/// 读项目 manifest，返回运行时 + 生产依赖数（§5.6）。
public enum ProjectMetaReader {

    public static func read(at root: URL) async throws -> ProjectMeta? {
        if let m = readNode(at: root) { return m }
        if let m = readCargo(at: root) { return m }
        if let m = readGo(at: root) { return m }
        if let m = readPyproject(at: root) { return m }
        return nil
    }

    static func readNode(at root: URL) -> ProjectMeta? {
        let f = root.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: f),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let deps = (json["dependencies"] as? [String: Any]) ?? [:]
        return ProjectMeta(runtime: "node", dependencyCount: deps.count, manifestFile: "package.json")
    }

    static func readCargo(at root: URL) -> ProjectMeta? {
        let f = root.appendingPathComponent("Cargo.toml")
        guard let content = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        return ProjectMeta(runtime: "rust",
                           dependencyCount: countTomlSection(content, section: "[dependencies]"),
                           manifestFile: "Cargo.toml")
    }

    static func readGo(at root: URL) -> ProjectMeta? {
        let f = root.appendingPathComponent("go.mod")
        guard let content = try? String(contentsOf: f, encoding: .utf8) else { return nil }
        return ProjectMeta(runtime: "go",
                           dependencyCount: countGoRequires(content),
                           manifestFile: "go.mod")
    }

    static func readPyproject(at root: URL) -> ProjectMeta? {
        let f = root.appendingPathComponent("pyproject.toml")
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        let content = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
        return ProjectMeta(runtime: "python",
                           dependencyCount: countTomlSection(content, section: "[project]", subsection: "dependencies"),
                           manifestFile: "pyproject.toml")
    }

    static func countTomlSection(_ content: String, section: String) -> Int {
        var inSection = false, count = 0
        for line in content.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inSection = t == section; continue }
            if inSection && t.contains("=") { count += 1 }
        }
        return count
    }

    static func countTomlSection(_ content: String, section: String, subsection: String) -> Int {
        var inSection = false
        for line in content.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inSection = t == section; continue }
            if inSection && t.hasPrefix("\(subsection)") {
                let after = t.split(separator: "=", maxSplits: 1).last ?? ""
                return after.split(separator: ",").filter { $0.contains("\"") }.count
            }
        }
        return 0
    }

    static func countGoRequires(_ content: String) -> Int {
        var inBlock = false, count = 0
        for line in content.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "require (" { inBlock = true; continue }
            if t == ")" && inBlock { inBlock = false; continue }
            if inBlock && !t.isEmpty && !t.hasPrefix("//") { count += 1 }
            if t.hasPrefix("require ") && !t.contains("(") { count += 1 }  // 单行 require
        }
        return count
    }
}
