import Testing
import Foundation
@testable import DevHubCore

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ops-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("ScriptDetector")
struct ScriptDetectorTests {

    @Test func detectsNpmScripts() async throws {
        let dir = try makeTempDir()
        try #"{"scripts":{"dev":"vite","build":"vite build"}}"#.write(toFile: dir.appendingPathComponent("package.json").path, atomically: true, encoding: .utf8)
        let scripts = try await ScriptDetector.detect(at: dir)
        let names = Set(scripts.map(\.name))
        #expect(names.contains("dev"))
        #expect(names.contains("build"))
        #expect(scripts.allSatisfy { $0.source == .npm })
        let dev = scripts.first { $0.name == "dev" }!
        #expect(dev.command == "npm run dev")
        #expect(dev.executable == "npm")
        #expect(dev.arguments == ["run", "dev"])
    }

    @Test("manifest-controlled names remain argv data, never shell syntax")
    func detectedNamesAreSafeArguments() async throws {
        let dir = try makeTempDir()
        try #"{"scripts":{"dev; touch /tmp/pwned":"vite"}}"#.write(
            toFile: dir.appendingPathComponent("package.json").path,
            atomically: true,
            encoding: .utf8
        )

        let script = try #require(try await ScriptDetector.detect(at: dir).first)
        #expect(script.executable == "npm")
        #expect(script.arguments == ["run", "dev; touch /tmp/pwned"])
    }

    @Test func ignoresMissingManifests() async throws {
        let dir = try makeTempDir()
        let scripts = try await ScriptDetector.detect(at: dir)
        #expect(scripts.isEmpty)
    }

    @Test func packageJsonWithoutScriptsYieldsNothing() async throws {
        let dir = try makeTempDir()
        try #"{"name":"x","version":"1.0.0"}"#.write(toFile: dir.appendingPathComponent("package.json").path, atomically: true, encoding: .utf8)
        #expect(try await ScriptDetector.detect(at: dir).isEmpty)
    }

    @Test func detectsMakefileTargets() async throws {
        let dir = try makeTempDir()
        let content = """
        .PHONY: build test
        build:
        \tswift build
        test:
        \tswift test
        """
        try content.write(toFile: dir.appendingPathComponent("Makefile").path, atomically: true, encoding: .utf8)
        let scripts = try await ScriptDetector.detect(at: dir)
        let names = Set(scripts.map(\.name))
        #expect(names == ["build", "test"])
        #expect(scripts.allSatisfy { $0.source == .makefile })
    }

    @Test func detectsDockerComposeServices() async throws {
        let dir = try makeTempDir()
        try """
        services:
          web:
            image: nginx
          db:
            image: postgres
        """.write(toFile: dir.appendingPathComponent("docker-compose.yml").path, atomically: true, encoding: .utf8)
        let scripts = try await ScriptDetector.detect(at: dir)
        let names = Set(scripts.map(\.name))
        #expect(names == ["db", "web"])
        #expect(scripts.allSatisfy { $0.source == .compose })
    }

    @Test func detectsProcfileEntries() async throws {
        let dir = try makeTempDir()
        try """
        web: node server.js
        worker: ruby worker.rb
        """.write(toFile: dir.appendingPathComponent("Procfile").path, atomically: true, encoding: .utf8)
        let scripts = try await ScriptDetector.detect(at: dir)
        let names = Set(scripts.map(\.name))
        #expect(names == ["web", "worker"])
        let web = scripts.first { $0.name == "web" }!
        #expect(web.command == "node server.js")
    }
}

@Suite("ProjectMetaReader")
struct ProjectMetaReaderTests {

    @Test func readsNodeMeta() async throws {
        let dir = try makeTempDir()
        try #"{"name":"x","dependencies":{"express":"4","lodash":"4"},"devDependencies":{"jest":"29"}}"#.write(toFile: dir.appendingPathComponent("package.json").path, atomically: true, encoding: .utf8)
        let meta = try await ProjectMetaReader.read(at: dir)
        #expect(meta?.runtime == "node")
        #expect(meta?.dependencyCount == 2)  // 只算 dependencies，不算 devDeps
        #expect(meta?.manifestFile == "package.json")
    }

    @Test func readsCargoMeta() async throws {
        let dir = try makeTempDir()
        try """
        [package]
        name = "x"
        [dependencies]
        serde = "1"
        tokio = "1"
        """.write(toFile: dir.appendingPathComponent("Cargo.toml").path, atomically: true, encoding: .utf8)
        let meta = try await ProjectMetaReader.read(at: dir)
        #expect(meta?.runtime == "rust")
        #expect(meta?.dependencyCount == 2)
    }

    @Test func readsGoMod() async throws {
        let dir = try makeTempDir()
        try """
        module x
        go 1.22
        require (
            github.com/foo/bar v1
            github.com/baz v2
        )
        """.write(toFile: dir.appendingPathComponent("go.mod").path, atomically: true, encoding: .utf8)
        let meta = try await ProjectMetaReader.read(at: dir)
        #expect(meta?.runtime == "go")
        #expect(meta?.dependencyCount == 2)
    }

    @Test func noManifestReturnsNil() async throws {
        let dir = try makeTempDir()
        #expect(try await ProjectMetaReader.read(at: dir) == nil)
    }
}

@Suite("LocalProcessRunner")
struct LocalProcessRunnerTests {

    @Test func spawnEchoCapturesStdout() async throws {
        let runner = LocalProcessRunner()
        let cfg = LocalProcessRunner.LaunchConfig(workingDir: try makeTempDir(),
                                                  command: "/bin/echo hello-devhub", timeout: 5)
        let lines = try await runner.runToCompletion(cfg: cfg)
        #expect(lines.contains { $0.stream == .stdout && $0.text.contains("hello-devhub") })
    }

    @Test func capturesStderr() async throws {
        let runner = LocalProcessRunner()
        let cfg = LocalProcessRunner.LaunchConfig(workingDir: try makeTempDir(),
                                                  command: "/bin/sh -c 'echo err >&2'", timeout: 5)
        let lines = try await runner.runToCompletion(cfg: cfg)
        #expect(lines.contains { $0.stream == .stderr && $0.text.contains("err") })
    }

    @Test("同时持续排空 stdout/stderr，且大输出有界")
    func drainsBothPipesWithoutDeadlock() async throws {
        let runner = LocalProcessRunner()
        let cfg = LocalProcessRunner.LaunchConfig(
            workingDir: try makeTempDir(),
            executable: "/usr/bin/python3",
            arguments: [
                "-c",
                "import sys; sys.stderr.buffer.write(b'e' * 2000000); sys.stderr.flush(); print('ok')",
            ],
            timeout: 5
        )

        let lines = try await runner.runToCompletion(cfg: cfg)

        #expect(lines.contains { $0.stream == .stdout && $0.text == "ok" })
        #expect(lines.contains { $0.stream == .system && $0.text.contains("stderr 仅保留前") })
        #expect(!lines.contains { $0.text.contains("[timeout]") })
    }

    @Test("argv launch does not interpret shell metacharacters")
    func argvDoesNotInvokeShell() async throws {
        let dir = try makeTempDir()
        let marker = dir.appendingPathComponent("must-not-exist")
        let runner = LocalProcessRunner()
        let cfg = LocalProcessRunner.LaunchConfig(
            workingDir: dir,
            executable: "/bin/echo",
            arguments: ["safe; /usr/bin/touch \(marker.path)"],
            timeout: 5
        )

        let lines = try await runner.runToCompletion(cfg: cfg)

        #expect(lines.contains { $0.text.contains("safe; /usr/bin/touch") })
        #expect(FileManager.default.fileExists(atPath: marker.path) == false)
    }

    @Test func timeoutKillsProcess() async throws {
        let runner = LocalProcessRunner()
        let cfg = LocalProcessRunner.LaunchConfig(workingDir: try makeTempDir(),
                                                  command: "/bin/sleep 30", timeout: 1)
        let lines = try await runner.runToCompletion(cfg: cfg)
        // 超时后被 terminate——应有 system 行记录
        #expect(lines.contains { $0.stream == .system })
    }

    // MARK: 流式 API（§5.6 stream + terminateCurrent）

    @Test("stream 逐行 yield stdout")
    func streamYieldsStdoutLines() async throws {
        let runner = LocalProcessRunner()
        let workingDir = try makeTempDir()

        // Short-lived processes expose the race between the readability callback
        // and Process.terminationHandler. Repeat enough times to keep it covered.
        for _ in 0..<25 {
            let cfg = LocalProcessRunner.LaunchConfig(
                workingDir: workingDir,
                command: "/bin/sh -c 'echo line1; echo line2'", timeout: 5)
            var lines: [LocalProcessRunner.LogLine] = []
            for await line in await runner.stream(cfg: cfg) { lines.append(line) }
            let stdoutTexts = lines.filter { $0.stream == .stdout }.map(\.text)
            #expect(stdoutTexts.contains("line1"))
            #expect(stdoutTexts.contains("line2"))
        }
    }

    @Test("stream 完成后不再持有进程（currentProcessIsRunning=false）")
    func streamReleasesProcess() async throws {
        let runner = LocalProcessRunner()
        let cfg = LocalProcessRunner.LaunchConfig(
            workingDir: try makeTempDir(), command: "/bin/echo done", timeout: 5)
        for await _ in await runner.stream(cfg: cfg) {}
        let stillRunning = await runner.currentProcessIsRunning()
        #expect(!stillRunning)
    }

    @Test("terminateCurrent 中止正在运行的流式进程")
    func terminateCurrentStopsLongProcess() async throws {
        let runner = LocalProcessRunner()
        let cfg = LocalProcessRunner.LaunchConfig(
            workingDir: try makeTempDir(), command: "/bin/sleep 30", timeout: 60)
        let collectTask = Task<[LocalProcessRunner.LogLine], Never> {
            var lines: [LocalProcessRunner.LogLine] = []
            for await line in await runner.stream(cfg: cfg) { lines.append(line) }
            return lines
        }
        // 给进程一点启动时间，然后终止
        try await Task.sleep(nanoseconds: 300_000_000)
        await runner.terminateCurrent()
        let lines = await collectTask.value
        // 终止后应有 system 行（被终止/退出）
        #expect(lines.contains { $0.stream == .system })
    }
}
