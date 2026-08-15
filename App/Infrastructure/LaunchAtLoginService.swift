import Foundation
import ServiceManagement

enum LaunchAtLoginState: Sendable, Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable

    var isRequested: Bool {
        self == .enabled || self == .requiresApproval
    }
}

enum LaunchAtLoginError: LocalizedError, Equatable {
    case requiresApproval
    case unavailable
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            return String(localized: "DevHub 已请求登录时启动，但仍需在“系统设置 → 通用 → 登录项”中批准。")
        case .unavailable:
            return String(localized: "当前 DevHub 无法注册为登录项。请使用正式签名的完整 .app 包。")
        case .operationFailed(let message):
            return String(localized: "更新登录项失败：\(message)")
        }
    }
}

@MainActor
protocol LaunchAtLoginManaging: AnyObject {
    var state: LaunchAtLoginState { get }
    func setEnabled(_ enabled: Bool) throws
}

@MainActor
protocol MainAppServiceControlling: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: MainAppServiceControlling {}

@MainActor
final class SystemLaunchAtLoginManager: LaunchAtLoginManaging {
    private let service: any MainAppServiceControlling

    init(service: any MainAppServiceControlling = SMAppService.mainApp) {
        self.service = service
    }

    var state: LaunchAtLoginState {
        switch service.status {
        case .notRegistered:
            return .disabled
        case .enabled:
            return .enabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .unavailable
        @unknown default:
            return .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                switch state {
                case .enabled:
                    return
                case .requiresApproval:
                    throw LaunchAtLoginError.requiresApproval
                case .unavailable:
                    throw LaunchAtLoginError.unavailable
                case .disabled:
                    try service.register()
                }
            } else {
                switch state {
                case .disabled:
                    return
                case .unavailable:
                    throw LaunchAtLoginError.unavailable
                case .enabled, .requiresApproval:
                    try service.unregister()
                }
            }
        } catch let error as LaunchAtLoginError {
            throw error
        } catch {
            throw LaunchAtLoginError.operationFailed(error.localizedDescription)
        }

        switch (enabled, state) {
        case (true, .enabled), (false, .disabled):
            return
        case (true, .requiresApproval):
            throw LaunchAtLoginError.requiresApproval
        case (_, .unavailable):
            throw LaunchAtLoginError.unavailable
        default:
            throw LaunchAtLoginError.operationFailed(
                String(localized: "系统未应用请求的登录项状态。")
            )
        }
    }
}
