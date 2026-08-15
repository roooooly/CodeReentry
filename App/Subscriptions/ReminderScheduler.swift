import Foundation
import UserNotifications
import DevHubCore

/// 把 UNUserNotificationCenter 抽象成协议（§5.4 提醒），便于测试注入 mock，
/// 否则测试会触发真实系统授权请求。
protocol NotificationCenterProtocol: Sendable {
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
}

/// Avoid a retroactive Sendable conformance on Apple's notification-center
/// class. Older Swift 6 compilers reject that conformance outside the framework
/// that defines the class; this adapter keeps the concurrency boundary explicit.
final class SystemNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// 订阅续费提醒调度（§5.4）。
/// 首次 schedule 先请求授权；拒绝则不调度（其余功能不受影响）。
final class ReminderScheduler: @unchecked Sendable {
    let center: NotificationCenterProtocol
    private let didAuthorizeLock = NSLock()
    private var didAuthorize = false

    init(center: NotificationCenterProtocol) { self.center = center }

    static func identifier(for subscriptionId: UUID) -> String {
        "devhub.subscription.\(subscriptionId.uuidString)"
    }

    func schedule(
        subscriptionId: UUID,
        name: String,
        renewal: Date,
        daysBefore: Int
    ) async throws {
        if !didAuthorizeLock.withLock({ didAuthorize }) {
            let granted = try await center.requestAuthorization()
            didAuthorizeLock.withLock { didAuthorize = true }
            guard granted else { return }
        }
        let fireDate = Calendar.current.date(byAdding: .day, value: -daysBefore, to: renewal) ?? renewal
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour], from: fireDate)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let content = UNMutableNotificationContent()
        content.title = String(localized: "订阅即将续费")
        content.body = "\(name) " + String(localized: "将于 \(Self.formatted(renewal)) 续费")
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: Self.identifier(for: subscriptionId),
            content: content, trigger: trigger
        )
        try await center.add(req)
    }

    func cancel(subscriptionId: UUID) {
        center.removePendingNotificationRequests(
            withIdentifiers: [Self.identifier(for: subscriptionId)]
        )
    }

    private static func formatted(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .none)
    }
}
