import Foundation

public enum ProjectSignal: String, Sendable, Equatable, CaseIterable {
    case git
    case packageJson
    case cargo
    case xcodeproj
    case goMod
    case pyproject
}

public struct ScannedProject: Sendable, Equatable {
    public let url: URL
    public let signals: Set<ProjectSignal>
    public init(url: URL, signals: Set<ProjectSignal>) {
        self.url = url
        self.signals = signals
    }
}

public struct ProjectScanner: Sendable {
    public let rootURL: URL
    public let maxDepth: Int

    public init(rootURL: URL, maxDepth: Int = 3) {
        self.rootURL = rootURL
        self.maxDepth = maxDepth
    }

    public func scan() throws -> [ScannedProject] {
        var results: [ScannedProject] = []
        let fm = FileManager.default
        try walk(rootURL, depth: 0, fm: fm, into: &results)
        return results.sorted { $0.url.path < $1.url.path }
    }

    private func walk(_ dir: URL, depth: Int, fm: FileManager, into results: inout [ScannedProject]) throws {
        guard depth <= maxDepth else { return }
        let signals = detectSignals(in: dir, fm: fm)
        if !signals.isEmpty {
            results.append(ScannedProject(url: dir, signals: signals))
            return
        }
        let contents = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for sub in contents where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            try walk(sub, depth: depth + 1, fm: fm, into: &results)
        }
    }

    private func detectSignals(in url: URL, fm: FileManager) -> Set<ProjectSignal> {
        var s: Set<ProjectSignal> = []
        let names = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        let nameSet = Set(names.map { $0.lastPathComponent })
        if nameSet.contains(".git") { s.insert(.git) }
        if nameSet.contains("package.json") { s.insert(.packageJson) }
        if nameSet.contains("Cargo.toml") { s.insert(.cargo) }
        if nameSet.contains("go.mod") { s.insert(.goMod) }
        if nameSet.contains("pyproject.toml") { s.insert(.pyproject) }
        if names.contains(where: { $0.pathExtension == "xcodeproj" }) { s.insert(.xcodeproj) }
        return s
    }
}
