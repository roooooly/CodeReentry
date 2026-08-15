import Foundation
import Security

/// 密钥存取最小接口。生产使用 ``KeychainStore``，UI 测试可注入失败实现，
/// 从而验证写入失败时不会提前提交 SwiftData 状态或关闭编辑表单。
public protocol KeychainStoring: Sendable {
    @discardableResult
    func set(toolId: String, envKey: String, value: String) throws -> OSStatus
    func get(toolId: String, envKey: String) throws -> String?
    @discardableResult
    func delete(toolId: String, envKey: String) throws -> OSStatus
}

/// 工具密钥存取（§4.1 §5.2）。
/// service 固定，account = "<toolId>.<envKey>"。
/// 不导出、不日志（§8.4 §8.5）。
public struct KeychainStore: KeychainStoring, Sendable {
    public static let service = "io.github.roooooly.devhub.tool-secrets"

    public init() {}

    public static func account(toolId: String, envKey: String) -> String {
        "\(toolId).\(envKey)"
    }

    @discardableResult
    public func set(toolId: String, envKey: String, value: String) throws -> OSStatus {
        let data = Data(value.utf8)
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(toolId: toolId, envKey: envKey),
        ]
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        // 先原位更新，避免“先删旧值、再写新值”在第二步失败时永久丢失密钥。
        let updateStatus = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return updateStatus }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandled(updateStatus)
        }

        var add = identity
        add.merge(update) { _, new in new }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
        return status
    }

    public func get(toolId: String, envKey: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(toolId: toolId, envKey: envKey),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandled(status) }
        guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return s
    }

    @discardableResult
    public func delete(toolId: String, envKey: String) throws -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account(toolId: toolId, envKey: envKey),
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandled(status)
        }
        return status
    }
}

public enum KeychainError: Error, Equatable, LocalizedError {
    case unhandled(OSStatus)
    case invalidData

    public var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            let statusCode = String(status)
            let systemMessage = SecCopyErrorMessageString(status, nil) as String?
            if let systemMessage {
                return String(localized: "Keychain 操作失败（\(statusCode)）：\(systemMessage)")
            }
            return String(localized: "Keychain 操作失败（\(statusCode)）。")
        case .invalidData:
            return String(localized: "Keychain 中的密钥数据不是有效的 UTF-8 文本。")
        }
    }
}
