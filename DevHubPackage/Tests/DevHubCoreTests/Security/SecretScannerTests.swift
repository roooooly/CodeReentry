import Testing
import Foundation
@testable import DevHubCore

@Suite("SecretScanner")
struct SecretScannerTests {

    @Test("AWS access key pattern")
    func awsKey() {
        let hits = SecretScanner.scan("环境变量 AKIAIOSFODNN7EXAMPLE 是测试 key")
        #expect(hits.contains(.awsKey))
    }

    @Test("GCP API key pattern")
    func gcpKey() {
        let hits = SecretScanner.scan("用 AIzaSyA1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ1234 调用")
        #expect(hits.contains(.gcpKey))
    }

    @Test("assignment-style secrets: api_key=, token:, password=")
    func assignmentStyle() {
        #expect(SecretScanner.scan("api_key=sk-abc123").contains(.assignment))
        #expect(SecretScanner.scan("apikey: foo123").contains(.assignment))
        #expect(SecretScanner.scan("OPENAI_TOKEN = abc").contains(.assignment))
        #expect(SecretScanner.scan("password: hunter2").contains(.assignment))
        #expect(SecretScanner.scan("secret=\"xyz\"").contains(.assignment))
    }

    @Test("PEM private key block")
    func pem() {
        let content = """
        -----BEGIN RSA PRIVATE KEY-----
        MIIEpAIBAAKCAQEA...
        -----END RSA PRIVATE KEY-----
        """
        #expect(SecretScanner.scan(content).contains(.pemPrivateKey))
    }

    @Test("long random string >= 32 hex/base64")
    func longRandom() {
        let hex32 = "0123456789abcdef0123456789abcdef"
        let b64_40 = "abcdefghijklmnopqrstuvwxyz0123456789ABCD"
        #expect(SecretScanner.scan("token: \(hex32)").contains(.longRandom) || SecretScanner.scan(hex32).contains(.longRandom))
        #expect(SecretScanner.scan(b64_40).contains(.longRandom))
    }

    @Test("short random string NOT flagged")
    func shortNotFlagged() {
        let hits = SecretScanner.scan("项目编号 abc123 短串")
        #expect(!hits.contains(.longRandom))
    }

    @Test("plain project context is clean")
    func cleanContext() {
        let context = """
        # ExampleApp 项目
        - 用 SwiftUI 写前端
        - 后端是 Rust
        - 主分支叫 main
        """
        #expect(SecretScanner.scan(context).isEmpty)
    }

    @Test("hasSecrets aggregates any hit")
    func hasSecrets() {
        #expect(SecretScanner.hasSecrets(in: "AKIAIOSFODNN7EXAMPLE"))
        #expect(!SecretScanner.hasSecrets(in: "no secrets here, just text"))
    }

    @Test("blocksPositionalInjection is true when any secret hit")
    func blocksPositional() {
        let result = SecretScanner.scanDetail("api_key=xyz")
        #expect(result.blocksPositionalInjection == true)
    }
}
