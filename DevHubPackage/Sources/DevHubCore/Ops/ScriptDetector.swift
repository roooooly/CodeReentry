import Foundation

public struct DetectedScript: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let source: ScriptSource
    public let name: String
    public let command: String
    public let rawCommand: String
    /// 非 nil 时按 argv 直接启动，不经 `/bin/sh -c`；Procfile 才保留 shell 命令语义。
    public let executable: String?
    public let arguments: [String]

    public init(source: ScriptSource, name: String, command: String, rawCommand: String) {
        self.source = source; self.name = name; self.command = command; self.rawCommand = rawCommand
        self.executable = nil; self.arguments = []
    }

    public init(source: ScriptSource, name: String, executable: String,
                arguments: [String], rawCommand: String) {
        self.source = source
        self.name = name
        self.executable = executable
        self.arguments = arguments
        self.command = ([executable] + arguments).joined(separator: " ")
        self.rawCommand = rawCommand
    }
}

public enum ScriptSource: String, Equatable, Sendable {
    case npm, makefile, compose, procfile
}

/// 扫描项目根目录的 manifest（package.json / Makefile / docker-compose / Procfile），
/// 返回统一的 DetectedScript 列表（§5.6 运维面板）。
public enum ScriptDetector {

    public static func detect(at root: URL) async throws -> [DetectedScript] {
        var out: [DetectedScript] = []
        out += detectNpm(at: root)
        out += detectMakefile(at: root)
        out += detectCompose(at: root)
        out += detectProcfile(at: root)
        return out.sorted { $0.name < $1.name }
    }

    static func detectNpm(at root: URL) -> [DetectedScript] {
        let f = root.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: f),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else { return [] }
        return scripts.map { (name, raw) in
            DetectedScript(
                source: .npm, name: name, executable: "npm",
                arguments: ["run", name], rawCommand: raw
            )
        }
    }

    static func detectMakefile(at root: URL) -> [DetectedScript] {
        let f = root.appendingPathComponent("Makefile")
        guard let content = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        var result: [DetectedScript] = []
        for line in content.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            // 跳过空行、注释、recipe 行（tab 开头）、GNU make 特殊目标（以 . 开头如 .PHONY）
            guard !s.isEmpty, !s.hasPrefix("#"), !line.hasPrefix("\t"), !s.hasPrefix(".") else { continue }
            if let colon = s.firstIndex(of: ":") {
                let target = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
                if !target.isEmpty && !target.contains(" ") {
                    result.append(DetectedScript(
                        source: .makefile, name: target, executable: "make",
                        arguments: [target], rawCommand: s
                    ))
                }
            }
        }
        return result
    }

    static func detectCompose(at root: URL) -> [DetectedScript] {
        for name in ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"] {
            let f = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: f.path) else { continue }
            guard let content = try? String(contentsOf: f, encoding: .utf8),
                  let services = YamlLikeServices.parse(content) else { return [] }
            return services.map { svc in
                DetectedScript(
                    source: .compose, name: svc, executable: "docker",
                    arguments: ["compose", "up", svc], rawCommand: "\(svc):"
                )
            }
        }
        return []
    }

    static func detectProcfile(at root: URL) -> [DetectedScript] {
        let f = root.appendingPathComponent("Procfile")
        guard let content = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        var result: [DetectedScript] = []
        for line in content.split(separator: "\n") {
            let s = line.trimmingCharacters(in: .whitespaces)
            guard let colon = s.firstIndex(of: ":") else { continue }
            let name = String(s[..<colon]).trimmingCharacters(in: .whitespaces)
            let cmd = String(s[s.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                result.append(DetectedScript(source: .procfile, name: name, command: cmd, rawCommand: cmd))
            }
        }
        return result
    }
}

/// 极简 YAML services 解析器——只取顶层 `services:` 下两空格缩进的服务名。
/// 非完整 YAML 解析器（运维面板只需 service 名列表）。
enum YamlLikeServices {
    static func parse(_ content: String) -> [String]? {
        var inServices = false
        var services: [String] = []
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 {
                inServices = trimmed.hasPrefix("services:")
                continue
            }
            if inServices && indent == 2 && trimmed.hasSuffix(":") {
                let name = trimmed.dropLast().trimmingCharacters(in: .whitespaces)
                services.append(String(name))
            }
        }
        return services
    }
}
