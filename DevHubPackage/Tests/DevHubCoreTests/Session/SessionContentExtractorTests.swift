import Testing
import Foundation
@testable import DevHubCore

@Suite("SessionContentExtractor")
struct SessionContentExtractorTests {

    @Test("纯文本字符串原样返回")
    func plainString() {
        #expect(SessionContentExtractor.text(from: "hello") == "hello")
        #expect(SessionContentExtractor.text(from: "") == nil)
    }

    @Test("文本数组拼接，默认跳过 tool_use/thinking")
    func textArraySkipsToolUseByDefault() {
        // Claude assistant content 数组形态
        let content: [Any] = [
            ["type": "text", "text": "我来执行命令"],
            ["type": "tool_use", "id": "t1", "name": "Bash",
             "input": ["command": "ls"] as [String: Any]],
            ["type": "thinking", "thinking": "internal"]
        ]
        // 默认 includeToolUse=false：只剩文本块
        #expect(SessionContentExtractor.text(from: content) == "我来执行命令")
    }

    @Test("includeToolUse=true 时 tool_use 渲染成可读文本")
    func textArrayIncludesToolUse() {
        let content: [Any] = [
            ["type": "text", "text": "我来执行命令"],
            ["type": "tool_use", "id": "t1", "name": "Bash",
             "input": ["command": "ls"] as [String: Any]]
        ]
        let result = SessionContentExtractor.text(from: content, includeToolUse: true)
        #expect(result != nil)
        // 文本和工具调用都在
        #expect(result!.contains("我来执行命令"))
        #expect(result!.contains("Bash"))
        #expect(result!.contains("ls"))
    }

    @Test("toolUseBlocks 抽取 name + input")
    func toolUseBlocksExtraction() {
        let content: [Any] = [
            ["type": "text", "text": "ok"],
            ["type": "tool_use", "name": "Read", "input": ["path": "/a"] as [String: Any]],
            ["type": "tool_use", "name": "Bash", "input": ["command": "pwd"] as [String: Any]]
        ]
        let blocks = SessionContentExtractor.toolUseBlocks(from: content)
        #expect(blocks.count == 2)
        #expect(blocks[0].name == "Read")
        #expect(blocks[0].input.contains("/a"))
        #expect(blocks[1].name == "Bash")
        #expect(blocks[1].input.contains("pwd"))
    }

    @Test("toolUseBlocks 对 Codex function_call（arguments 字符串）也生效")
    func functionCallArguments() {
        let content: [Any] = [
            ["type": "function_call", "name": "shell",
             "arguments": "{\"cmd\":\"echo hi\"}"]
        ]
        let blocks = SessionContentExtractor.toolUseBlocks(from: content)
        #expect(blocks.count == 1)
        #expect(blocks[0].name == "shell")
        #expect(blocks[0].input.contains("echo hi"))
    }

    @Test("toolUseBlocks 空输入与非数组输入返回空")
    func toolUseBlocksEmpty() {
        #expect(SessionContentExtractor.toolUseBlocks(from: nil).isEmpty)
        #expect(SessionContentExtractor.toolUseBlocks(from: "string").isEmpty)
        #expect(SessionContentExtractor.toolUseBlocks(from: [["type": "text", "text": "x"] as [String: Any]]).isEmpty)
    }
}
