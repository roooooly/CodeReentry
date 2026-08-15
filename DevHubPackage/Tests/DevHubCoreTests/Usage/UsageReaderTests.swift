import Testing
import Foundation
@testable import DevHubCore

@Suite("Usage readers")
struct UsageReaderTests {

    private func writeFile(_ content: String, ext: String = "jsonl") throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-usage-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("test.\(ext)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Claude

    @Test("ClaudeUsageReader.parse 抽取 assistant usage")
    func claudeParse() throws {
        let jsonl = """
        {"type":"user","message":{"content":"hi"},"cwd":"/tmp/P","timestamp":"2025-06-15T10:00:00.000Z","sessionId":"s1"}
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":100,"cache_creation_input_tokens":50,"cache_read_input_tokens":200,"output_tokens":30}},"cwd":"/tmp/P","timestamp":"2025-06-15T10:00:01.000Z","sessionId":"s1"}
        {"type":"assistant","message":{"model":"claude-sonnet-4-5","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}},"cwd":"/tmp/P","timestamp":"2025-06-15T10:00:02.000Z","sessionId":"s1"}
        """
        let file = try writeFile(jsonl)
        let reader = ClaudeUsageReader(projectsRoot: file.deletingLastPathComponent())
        // parse 是按单文件：直接给它文件
        let records = reader.parse(file: file)
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.tool == "claude-code" })
        #expect(records[0].model == "claude-sonnet-4-5")
        #expect(records[0].inputTokens == 100)
        #expect(records[0].cacheWriteTokens == 50)
        #expect(records[0].cacheReadTokens == 200)
        #expect(records[0].outputTokens == 30)
        #expect(records[0].cwd == "/tmp/P")
        #expect(records[1].outputTokens == 5)
    }

    @Test("ClaudeUsageReader 跳过非 assistant 行")
    func claudeSkipsNonAssistant() throws {
        let jsonl = """
        {"type":"summary","summary":"x"}
        {"type":"user","message":{"content":"hi"}}
        {"type":"assistant","message":{"model":"m","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
        """
        let file = try writeFile(jsonl)
        let reader = ClaudeUsageReader(projectsRoot: file.deletingLastPathComponent())
        let records = reader.parse(file: file)
        #expect(records.count == 1)
        #expect(records[0].inputTokens == 7)
    }

    // MARK: - Codex

    @Test("CodexUsageReader.parse 取最后一条 token_count 的累计用量（非累加所有事件）")
    func codexParse() throws {
        // last_token_usage 是会话内累计值（随 turn 递增），累加所有事件会重复计数。
        // 正确语义：每个会话文件取最后一条 token_count 的累计 last。
        let jsonl = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":14132,"cached_input_tokens":7040,"output_tokens":121,"reasoning_output_tokens":103,"total_tokens":14253},"total_token_usage":{"input_tokens":99999}}},"timestamp":"2025-06-15T10:00:00.000Z"}
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":15000,"cached_input_tokens":7100,"output_tokens":200,"reasoning_output_tokens":103,"total_tokens":30000}}},"timestamp":"2025-06-15T10:01:00.000Z"}
        {"type":"session_meta","payload":{"id":"abc"}}
        """
        let file = try writeFile(jsonl)
        let reader = CodexUsageReader(rootURL: file.deletingLastPathComponent().deletingLastPathComponent(),
                                       model: "gpt-5.1")
        let records = reader.parse(file: file)
        // 只返回最后一条（累计值，非累加）
        #expect(records.count == 1)
        // 取最后一条 last（input=15000），而非第一条（14132），更非累加（29132）
        #expect(records[0].inputTokens == 15000)
        #expect(records[0].cacheReadTokens == 7100)
        #expect(records[0].outputTokens == 200)
        #expect(records[0].reasoningTokens == 103)
    }

    @Test("CodexUsageReader.parseLatestRateLimit 取最新一条")
    func codexRateLimit() throws {
        let jsonl = """
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10.0,"window_minutes":300,"resets_at":1750000100},"secondary":{"used_percent":2.0,"window_minutes":10080,"resets_at":1750800000}}},"timestamp":"2025-06-15T10:00:00.000Z"}
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":29.0,"window_minutes":300,"resets_at":1750000200},"secondary":{"used_percent":4.0,"window_minutes":10080,"resets_at":1750800100}}},"timestamp":"2025-06-15T11:00:00.000Z"}
        """
        let file = try writeFile(jsonl)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let reader = CodexUsageReader(rootURL: file.deletingLastPathComponent().deletingLastPathComponent(),
                                       model: "gpt-5.1")
        let latest = reader.parseLatestRateLimit(file: file, iso: iso)
        #expect(latest != nil)
        // 取 11:00 那条（更新）
        #expect(latest?.snapshot.primaryUsedPercent == 29.0)
        #expect(latest?.snapshot.secondaryUsedPercent == 4.0)
        #expect(latest?.snapshot.primaryWindowMinutes == 300)
    }

    @Test("CodexUsageReader config.toml model 解析")
    func codexModelFromConfig() throws {
        let toml = """
        model = "gpt-5.6-sol"
        model_reasoning_effort = "max"
        """
        let file = try writeFile(toml, ext: "toml")
        let model = CodexUsageReader.readModelFromConfig(at: file)
        #expect(model == "gpt-5.6-sol")
    }

    @Test("CodexUsageReader config.toml 精确匹配 model 键，不误匹配 model_provider 等")
    func codexModelFromConfigExactKey() throws {
        // 真实 config.toml 里 model_provider 往往排在 model 之前；
        // 旧实现 hasPrefix("model") 会命中 model_provider 返回 "openai"。
        let toml = """
        model_provider = "openai"
        model_reasoning_effort = "max"
        model = "gpt-5.1"
        """
        let file = try writeFile(toml, ext: "toml")
        let model = CodexUsageReader.readModelFromConfig(at: file)
        #expect(model == "gpt-5.1")
    }

    @Test("CodexUsageReader.readAllAndRateLimit 单次遍历同时返回 records 与 rateLimit")
    func codexReadAllAndRateLimit() async throws {
        // 构造 ~/.codex/sessions/<uuid>/rollout-*.jsonl 目录结构
        let codexRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("devhub-codex-test-\(UUID().uuidString)", isDirectory: true)
        let sessionDir = codexRoot.appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let jsonl = """
        {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":10,"reasoning_output_tokens":0,"total_tokens":110}},"rate_limits":{"primary":{"used_percent":42.0,"window_minutes":300,"resets_at":1750000100},"secondary":{"used_percent":5.0,"window_minutes":10080,"resets_at":1750800000}}},"timestamp":"2025-06-15T10:00:00.000Z"}
        """
        let file = sessionDir.appendingPathComponent("rollout-2025-06-15T10-00-00-\(UUID().uuidString).jsonl")
        try jsonl.write(to: file, atomically: true, encoding: .utf8)

        let reader = CodexUsageReader(rootURL: codexRoot, model: "gpt-5.1")
        let bundle = await reader.readAllAndRateLimit()
        // 单次遍历同时拿到 usage 与 rate_limit
        #expect(bundle.records.count == 1)
        #expect(bundle.records[0].inputTokens == 100)
        #expect(bundle.rateLimit?.primaryUsedPercent == 42.0)
        #expect(bundle.rateLimit?.secondaryUsedPercent == 5.0)
    }
}
