import Testing
import Foundation
@testable import DevHubCore

@Suite("LauncherScriptBuilder")
struct LauncherScriptBuilderTests {

    private func makeBuilder() throws -> LauncherScriptBuilder {
        let testCache = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-launcher-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testCache, withIntermediateDirectories: true)
        return LauncherScriptBuilder(cacheRoot: testCache)
    }

    @Test("writes 0700 .sh at Caches/DevHub/launchers/<uuid>.sh")
    func writesScript() async throws {
        let builder = try makeBuilder()
        let path = try await builder.write(
            cwd: "/Users/example/Projects/ExampleApp",
            executable: "claude",
            arguments: []
        )
        #expect(path.hasSuffix(".sh"))
        #expect(path.contains("/devhub-launcher-test-"))

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = attrs[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o700)

        let content = try String(contentsOfFile: path)
        #expect(content.hasPrefix("#!/bin/bash"))
        #expect(content.contains("cd '/Users/example/Projects/ExampleApp'"))
        #expect(content.contains("'claude'"))
        #expect(content.contains("trap cleanup EXIT"))
    }

    @Test("cd path with spaces is correctly single-quoted")
    func cdWithSpaces() async throws {
        let builder = try makeBuilder()
        let path = try await builder.write(
            cwd: "/Users/example/My Projects/ExampleApp",
            executable: "codex",
            arguments: ["resume", "abc"]
        )
        let content = try String(contentsOfFile: path)
        #expect(content.contains("cd '/Users/example/My Projects/ExampleApp'"))
    }

    @Test("memory content goes via $(cat '<memfile>'), not literal")
    func memoryViaCat() async throws {
        let builder = try makeBuilder()
        let memFile = builder.cacheRoot.appendingPathComponent("inj-\(UUID().uuidString).md")
        try Data("memory content".utf8).write(to: memFile)
        let path = try await builder.write(
            cwd: "/tmp/P",
            executable: "/Applications/ChatGPT.app/Contents/Resources/codex",
            arguments: ["resume", "abc", "$__DEVHUB_MEMORY_FILE__\(memFile.path)"]
        )
        let content = try String(contentsOfFile: path)
        // 外包双引号防止 word-splitting + globbing（spec §5.2 安全）
        #expect(content.contains(#""$(cat '"# + memFile.path + #"')""#))
        #expect(!content.contains("memory content"))
    }

    @Test("memory content with single quotes in cd path is safe")
    func memorySingleQuote() async throws {
        let builder = try makeBuilder()
        let path = try await builder.write(
            cwd: "/Users/example/it's a path",
            executable: "claude",
            arguments: []
        )
        let content = try String(contentsOfFile: path)
        #expect(content.contains(#"cd '/Users/example/it'\''s a path'"#))
    }

    @Test("memory content with backticks / $ / backslash is safe (via cat file)")
    func memorySpecialCharsSafe() async throws {
        let builder = try makeBuilder()
        let memFile = builder.cacheRoot.appendingPathComponent("inj-spec-\(UUID().uuidString).md")
        let nasty = "value `$USER` \\n `whoami` $HOME \"quote\""
        try Data(nasty.utf8).write(to: memFile)
        let path = try await builder.write(
            cwd: "/tmp/P",
            executable: "codex",
            arguments: ["resume", "x", "$__DEVHUB_MEMORY_FILE__\(memFile.path)"]
        )
        let content = try String(contentsOfFile: path)
        #expect(!content.contains("$USER"))
        #expect(!content.contains("`whoami`"))
        #expect(!content.contains("$HOME"))
        #expect(content.contains(#"$(cat '"# + memFile.path + #"')"#))
    }

    @Test("newlines in memory are safe (file content, not argv literal)")
    func memoryNewline() async throws {
        let builder = try makeBuilder()
        let memFile = builder.cacheRoot.appendingPathComponent("inj-nl-\(UUID().uuidString).md")
        let multiline = """
        line 1
        line 2
        line 3
        """
        try Data(multiline.utf8).write(to: memFile)
        let path = try await builder.write(
            cwd: "/tmp",
            executable: "codex",
            arguments: ["resume", "id", "$__DEVHUB_MEMORY_FILE__\(memFile.path)"]
        )
        let content = try String(contentsOfFile: path)
        #expect(content.components(separatedBy: "\n").filter { $0.contains("'codex'") }.count == 1)
    }

    @Test("empty memory: codex resume <id> without PROMPT")
    func emptyMemory() async throws {
        let builder = try makeBuilder()
        let path = try await builder.write(
            cwd: "/tmp/P",
            executable: "/Applications/ChatGPT.app/Contents/Resources/codex",
            arguments: ["resume", "abc"]
        )
        let content = try String(contentsOfFile: path)
        #expect(content.contains("'/Applications/ChatGPT.app/Contents/Resources/codex' 'resume' 'abc'"))
        #expect(!content.contains("$__DEVHUB_MEMORY_FILE__"))
        #expect(!content.contains("$(cat"))
    }

    @Test("comment header includes generation timestamp")
    func timestampHeader() async throws {
        let builder = try makeBuilder()
        let path = try await builder.write(cwd: "/tmp", executable: "claude", arguments: [])
        let content = try String(contentsOfFile: path)
        #expect(content.contains("# Generated by DevHub at"))
    }

    /// 端到端：真正运行生成的脚本，验证目标进程收到的 argv 正确。
    /// 这是唯一能抓 word-splitting/globbing bug 的测试类型（reviewer 发现的 CRITICAL bug 就属此类）。
    /// 用 `printf '%s\0' "$@"` 把 argv 以 NUL 分隔输出，再解析。
    @Test("end-to-end: multiline memory produces exactly ONE argv element (no word-splitting)")
    func e2eMultilineMemorySingleArg() async throws {
        let builder = try makeBuilder()
        let memFile = builder.cacheRoot.appendingPathComponent("e2e-\(UUID().uuidString).md")
        let multiline = """
        line 1 has spaces
        line 2 has * glob char
        line 3 has $HOME and `whoami`
        """
        try Data(multiline.utf8).write(to: memFile)

        // 用 printf 作为 stub "工具"：它接收所有 argv 并 NUL 分隔输出到 stdout
        let printfPath = "/usr/bin/printf"
        let scriptPath = try await builder.write(
            cwd: "/tmp",
            executable: printfPath,
            arguments: ["%s\\0", "$__DEVHUB_MEMORY_FILE__\(memFile.path)"],
            cleanupPaths: [memFile.path]
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: scriptPath)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // printf 把 argv 用 NUL 分隔。第一个 arg 是 format string "%s\0"，
        // 第二个 arg 应该是完整的 multiline（3 行作为一个 argv）。
        let parts = data.split(separator: 0)  // separator: NUL byte
        // printf 输出格式："%s\0" 应用到每个 arg，所以输出 = arg1 + NUL + arg2 + NUL
        // 第一个 part = "%s\0" 的求值 = arg1 内容（这里 format 自己就是 arg1，输出空？）
        // 实际 printf 行为：argv[0]=printf, argv[1]="%s\0", argv[2..]=memory
        // printf 把 format "%s\0" 应用到 argv[2:]，每个生成 "<content>\0"
        // 所以输出 = "<memory 完整内容>\0"
        #expect(parts.count >= 1)
        // memory 内容应该作为单个 argv 完整保留（3 行）
        let memoryArg = String(data: Data(parts[0]), encoding: .utf8) ?? ""
        #expect(memoryArg.contains("line 1 has spaces"))
        #expect(memoryArg.contains("line 2 has * glob char"))
        #expect(memoryArg.contains("line 3 has $HOME and `whoami`"))
        // 关键断言：glob 字符 * 不被展开（如果 word-splitting 了，* 会变成 cwd 文件名）
        #expect(memoryArg.contains("*"))
        // 关键断言：$HOME 不被展开（双引号内 $(cat) 不二次求值）
        #expect(memoryArg.contains("$HOME"))
        #expect(!FileManager.default.fileExists(atPath: scriptPath))
        #expect(!FileManager.default.fileExists(atPath: memFile.path))
    }

    @Test("environment is shell-quoted and launcher removes itself after exit")
    func environmentAndCleanup() async throws {
        let builder = try makeBuilder()
        let output = builder.cacheRoot.appendingPathComponent("env-output.txt")
        let script = try await builder.write(
            cwd: "/tmp", executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$DEVHUB_TEST_VALUE\" > \(output.path)"],
            environment: ["DEVHUB_TEST_VALUE": "space $HOME `whoami` ' quote"]
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: script)
        try process.run()
        process.waitUntilExit()

        #expect(try String(contentsOf: output, encoding: .utf8) == "space $HOME `whoami` ' quote")
        #expect(!FileManager.default.fileExists(atPath: script))
    }

    @Test("invalid environment key is rejected before script creation")
    func invalidEnvironmentKey() async throws {
        let builder = try makeBuilder()
        await #expect(throws: LauncherScriptError.invalidEnvironmentKey("BAD-KEY")) {
            _ = try await builder.write(
                cwd: "/tmp", executable: "/usr/bin/true", arguments: [],
                environment: ["BAD-KEY": "value"]
            )
        }
    }
}
