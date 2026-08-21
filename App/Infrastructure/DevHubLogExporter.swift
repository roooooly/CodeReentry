import Darwin
import Foundation

struct DevHubLogCommandResult: Sendable, Equatable {
    let stdout: Data
    let stderr: Data
    let exitCode: Int32
}

protocol DevHubLogCommandRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) async throws -> DevHubLogCommandResult
}

struct SystemDevHubLogCommandRunner: DevHubLogCommandRunning {
    func run(executableURL: URL, arguments: [String]) async throws -> DevHubLogCommandResult {
        try await Task.detached(priority: .utility) {
            let stdoutFile = try SecureTemporaryFile.create(
                in: FileManager.default.temporaryDirectory,
                prefix: "devhub-log-stdout"
            )
            let stderrFile = try SecureTemporaryFile.create(
                in: FileManager.default.temporaryDirectory,
                prefix: "devhub-log-stderr"
            )
            defer {
                try? stdoutFile.handle.close()
                try? stderrFile.handle.close()
                try? FileManager.default.removeItem(at: stdoutFile.url)
                try? FileManager.default.removeItem(at: stderrFile.url)
            }

            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = stdoutFile.handle
            process.standardError = stderrFile.handle
            process.environment = [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8",
            ]

            try process.run()
            process.waitUntilExit()
            try stdoutFile.handle.close()
            try stderrFile.handle.close()

            return DevHubLogCommandResult(
                stdout: try Data(contentsOf: stdoutFile.url),
                stderr: try Data(contentsOf: stderrFile.url),
                exitCode: process.terminationStatus
            )
        }.value
    }
}

struct DevHubLogExportResult: Sendable, Equatable {
    let url: URL
    let byteCount: Int
}

protocol DevHubLogExporting: Sendable {
    func exportLastSevenDays(to destination: URL) async throws -> DevHubLogExportResult
}

enum DevHubLogExportError: LocalizedError, Equatable {
    case commandFailed(exitCode: Int32, message: String)
    case invalidDestination

    var errorDescription: String? {
        switch self {
        case .commandFailed(let exitCode, let message):
            return String(localized: "读取 CodeReentry 日志失败（退出码 \(exitCode)）：\(message)")
        case .invalidDestination:
            return String(localized: "请选择一个存在且可写入的文件夹来保存日志。")
        }
    }
}

actor DevHubLogExporter: DevHubLogExporting {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/log")
    static let arguments = [
        "show",
        "--last", "7d",
        "--style", "ndjson",
        "--info",
        "--debug",
        "--predicate", #"subsystem == "io.github.roooooly.devhub""#,
    ]

    private let runner: any DevHubLogCommandRunning

    init(runner: any DevHubLogCommandRunning = SystemDevHubLogCommandRunner()) {
        self.runner = runner
    }

    func exportLastSevenDays(to destination: URL) async throws -> DevHubLogExportResult {
        let output = try await runner.run(
            executableURL: Self.executableURL,
            arguments: Self.arguments
        )

        guard output.exitCode == 0 else {
            let rawError = String(decoding: output.stderr, as: UTF8.self)
            let redactedError = DevHubLogRedactor.redact(rawError)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let boundedError = String(redactedError.prefix(1_000))
            throw DevHubLogExportError.commandFailed(
                exitCode: output.exitCode,
                message: boundedError.isEmpty ? String(localized: "未知错误") : boundedError
            )
        }

        let rawLogs = String(decoding: output.stdout, as: UTF8.self)
        let redactedLogs = DevHubLogRedactor.redact(rawLogs)
        let data = Data(redactedLogs.utf8)
        try Self.writeSecurely(data, to: destination)
        return DevHubLogExportResult(url: destination, byteCount: data.count)
    }

    private static func writeSecurely(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw DevHubLogExportError.invalidDestination
        }

        let temporary = try SecureTemporaryFile.create(in: directory, prefix: ".devhub-log-export")
        defer {
            try? temporary.handle.close()
            try? FileManager.default.removeItem(at: temporary.url)
        }

        try temporary.handle.write(contentsOf: data)
        try temporary.handle.synchronize()
        try temporary.handle.close()

        let renameStatus = temporary.url.path.withCString { source in
            destination.path.withCString { target in
                Darwin.rename(source, target)
            }
        }
        guard renameStatus == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSFilePathErrorKey: destination.path]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }
}

enum DevHubLogRedactor {
    private static let sensitiveKey =
        #"(?:api[_-]?key|access[_-]?token|refresh[_-]?token|auth(?:orization)?|token|secret|password|passwd|client[_-]?secret)"#

    private static var rules: [(String, String)] {
        [
            (#"(?is)-----BEGIN[ A-Z]*PRIVATE KEY-----.*?-----END[ A-Z]*PRIVATE KEY-----"#, "<private-key:redacted>"),
            (#"(?i)\bBearer\s+[A-Za-z0-9._~+/=-]{8,}"#, "Bearer <redacted>"),
            (#"\bAKIA[0-9A-Z]{16}\b"#, "<redacted>"),
            (#"\bAIza[0-9A-Za-z_-]{35}\b"#, "<redacted>"),
            (#"\bsk-[A-Za-z0-9_-]{12,}\b"#, "<redacted>"),
            (#"\bgh[pousr]_[A-Za-z0-9]{16,}\b"#, "<redacted>"),
            (#"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#, "<redacted>"),
            (
                #"(?i)(["']?"# + sensitiveKey + #"["']?\s*[:=]\s*)(["'])[^"'\r\n]*\2"#,
                "$1$2<redacted>$2"
            ),
            (
                #"(?i)(["']?"# + sensitiveKey + #"["']?\s*[:=]\s*)(?!["'])[^,\r\n;}&\]"']+"#,
                "$1<redacted>"
            ),
            (#"\b[0-9a-fA-F]{32,}\b"#, "<redacted>"),
            (#"\b[A-Za-z0-9+/]{40,}={0,2}\b"#, "<redacted>"),
        ]
    }

    static func redact(_ text: String) -> String {
        rules.reduce(text) { current, rule in
            guard let regex = try? NSRegularExpression(
                pattern: rule.0,
                options: []
            ) else { return current }
            let range = NSRange(current.startIndex..., in: current)
            return regex.stringByReplacingMatches(
                in: current,
                options: [],
                range: range,
                withTemplate: rule.1
            )
        }
    }
}

private struct SecureTemporaryFile {
    let url: URL
    let handle: FileHandle

    static func create(in directory: URL, prefix: String) throws -> SecureTemporaryFile {
        for _ in 0..<10 {
            let url = directory.appendingPathComponent("\(prefix).\(UUID().uuidString)")
            let descriptor = url.path.withCString { path in
                Darwin.open(
                    path,
                    O_CREAT | O_EXCL | O_RDWR,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            if descriptor >= 0 {
                return SecureTemporaryFile(
                    url: url,
                    handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                )
            }
            if errno != EEXIST {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: url.path]
                )
            }
        }
        throw NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(EEXIST),
            userInfo: [NSFilePathErrorKey: directory.path]
        )
    }
}
