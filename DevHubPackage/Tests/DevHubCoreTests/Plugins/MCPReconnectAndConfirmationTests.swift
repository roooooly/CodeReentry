import Testing
import Foundation
@testable import DevHubCore

@Suite("MCPReconnectPolicy")
struct MCPReconnectPolicyTests {
    @Test("首次失败 nextDelay 返回基础值")
    func firstDelay() {
        let p = MCPReconnectPolicy(maxAttempts: 3, baseDelay: 0.01)
        #expect(p.nextDelay(afterAttempt: 0) == 0.01)
    }

    @Test("超过 maxAttempts 后返回 nil")
    func exhausts() {
        let p = MCPReconnectPolicy(maxAttempts: 3, baseDelay: 0.01)
        #expect(p.nextDelay(afterAttempt: 0) != nil)
        #expect(p.nextDelay(afterAttempt: 1) != nil)
        #expect(p.nextDelay(afterAttempt: 2) != nil)
        #expect(p.nextDelay(afterAttempt: 3) == nil)
    }

    @Test("指数退避乘数")
    func backoff() {
        let p = MCPReconnectPolicy(maxAttempts: 5, baseDelay: 0.01, multiplier: 2.0)
        #expect(p.nextDelay(afterAttempt: 0) == 0.01)
        #expect(p.nextDelay(afterAttempt: 1) == 0.02)
        #expect(p.nextDelay(afterAttempt: 2) == 0.04)
    }

    @Test("退避不超过 maxDelay")
    func cappedAtMaxDelay() {
        let p = MCPReconnectPolicy(maxAttempts: 10, baseDelay: 1.0, multiplier: 2.0, maxDelay: 5.0)
        #expect(p.nextDelay(afterAttempt: 0) == 1.0)
        #expect(p.nextDelay(afterAttempt: 3) == 5.0)  // 1*2^3=8 → capped 5
        #expect(p.nextDelay(afterAttempt: 9) == 5.0)
    }
}

@Suite("MCPConfirmationGate")
struct MCPConfirmationGateTests {
    @Test("confirmationPrompt 包含 command 与所有 args")
    func promptContainsCommand() {
        let server = MCPServerConfig(command: "npx",
                                     args: ["-y", "@modelcontextprotocol/server-filesystem", "/Users/example"],
                                     env: nil)
        let gate = MCPConfirmationGate(serverName: "fs", server: server)
        let prompt = gate.confirmationPrompt
        #expect(prompt.contains("npx"))
        #expect(prompt.contains("-y"))
        #expect(prompt.contains("@modelcontextprotocol/server-filesystem"))
        #expect(prompt.contains("/Users/example"))
        #expect(prompt.contains("fs"))
    }

    @Test("env 含 KEY/TOKEN/SECRET 时 warningLines 标注")
    func flagsEnvRisk() {
        let server = MCPServerConfig(command: "npx", args: [], env: ["API_KEY": "secret", "TOKEN": "x", "SAFE_VAR": "y"])
        let gate = MCPConfirmationGate(serverName: "fs", server: server)
        #expect(gate.warningLines.contains(where: { $0.contains("API_KEY") }))
        #expect(gate.warningLines.contains(where: { $0.contains("TOKEN") }))
        #expect(gate.warningLines.contains(where: { $0.contains("SAFE_VAR") }) == false)
    }

    @Test("decide 映射")
    func decision() {
        let server = MCPServerConfig(command: "echo", args: [], env: nil)
        let gate = MCPConfirmationGate(serverName: "fs", server: server)
        #expect(gate.decide(accepted: true) == .accepted)
        #expect(gate.decide(accepted: false) == .declined)
    }

    @Test("无 env 时 warningLines 为空")
    func noWarningsWithoutEnv() {
        let server = MCPServerConfig(command: "echo", args: [], env: nil)
        let gate = MCPConfirmationGate(serverName: "fs", server: server)
        #expect(gate.warningLines.isEmpty)
    }
}
