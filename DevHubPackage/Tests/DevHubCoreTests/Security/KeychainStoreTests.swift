import Testing
import Foundation
import Security
@testable import DevHubCore

@Suite("KeychainStore")
struct KeychainStoreTests {

    @Test("account key format is <toolId>.<envKey>")
    func accountFormat() {
        #expect(KeychainStore.account(toolId: "claude", envKey: "ANTHROPIC_API_KEY") == "claude.ANTHROPIC_API_KEY")
    }

    @Test("service is the spec-fixed value")
    func service() {
        #expect(KeychainStore.service == "io.github.roooooly.devhub.tool-secrets")
    }

    @Test("roundtrip set/get/delete a secret")
    func roundtrip() throws {
        let store = KeychainStore()
        let key = "test-\(UUID().uuidString)"
        defer { _ = try? store.delete(toolId: key, envKey: "TOKEN") }
        try store.set(toolId: key, envKey: "TOKEN", value: "sk-test-123")
        #expect(try store.get(toolId: key, envKey: "TOKEN") == "sk-test-123")
        try store.delete(toolId: key, envKey: "TOKEN")
        #expect(try store.get(toolId: key, envKey: "TOKEN") == nil)
    }

    @Test("overwrite replaces existing value")
    func overwrite() throws {
        let store = KeychainStore()
        let key = "test-overwrite-\(UUID().uuidString)"
        defer { _ = try? store.delete(toolId: key, envKey: "K") }
        try store.set(toolId: key, envKey: "K", value: "old")
        let referenceBefore = try persistentReference(toolId: key, envKey: "K")
        try store.set(toolId: key, envKey: "K", value: "new")
        let referenceAfter = try persistentReference(toolId: key, envKey: "K")
        #expect(try store.get(toolId: key, envKey: "K") == "new")
        // SecItemUpdate 保持同一个 Keychain item；先删后增会改变 persistent ref。
        #expect(referenceAfter == referenceBefore)
    }

    @Test("get returns nil for absent key (no throw)")
    func absent() throws {
        let store = KeychainStore()
        #expect(try store.get(toolId: "absent-\(UUID().uuidString)", envKey: "X") == nil)
    }

    @Test("Keychain errors provide an actionable message")
    func localizedError() {
        let error = KeychainError.unhandled(errSecAuthFailed)
        #expect(error.errorDescription?.contains("Keychain") == true)
        #expect(error.errorDescription?.contains("\(errSecAuthFailed)") == true)
    }

    private func persistentReference(toolId: String, envKey: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainStore.service,
            kSecAttrAccount as String: KeychainStore.account(toolId: toolId, envKey: envKey),
            kSecReturnPersistentRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let reference = item as? Data else {
            throw KeychainError.unhandled(status)
        }
        return reference
    }
}
