import Testing
import Foundation
import UserNotifications
@testable import DevHub

@Suite("ReminderScheduler")
struct ReminderSchedulerTests {

    @Test("首次 schedule 先请求授权")
    func requestsAuthOnFirstSchedule() async throws {
        let center = MockNotificationCenter()
        let scheduler = ReminderScheduler(center: center)
        let renewal = Date(timeIntervalSinceNow: 86400 * 10)
        try await scheduler.schedule(subscriptionId: UUID(), name: "ChatGPT", renewal: renewal, daysBefore: 3)
        #expect(center.requestAuthorizationCallCount == 1)
    }

    @Test("第二次 schedule 不再请求授权")
    func noRepeatAuth() async throws {
        let center = MockNotificationCenter()
        let scheduler = ReminderScheduler(center: center)
        let renewal = Date(timeIntervalSinceNow: 86400 * 10)
        try await scheduler.schedule(subscriptionId: UUID(), name: "A", renewal: renewal, daysBefore: 3)
        try await scheduler.schedule(subscriptionId: UUID(), name: "B", renewal: renewal, daysBefore: 3)
        #expect(center.requestAuthorizationCallCount == 1)
    }

    @Test("拒绝授权则不添加请求")
    func deniedSkipsScheduling() async throws {
        let center = MockNotificationCenter(granted: false)
        let scheduler = ReminderScheduler(center: center)
        let renewal = Date(timeIntervalSinceNow: 86400 * 10)
        try await scheduler.schedule(subscriptionId: UUID(), name: "X", renewal: renewal, daysBefore: 3)
        #expect(center.addedRequests.isEmpty)
    }

    @Test("授权后按 daysBefore 计算触发日期（renewal - 3 天）")
    func computesTriggerDate() async throws {
        let center = MockNotificationCenter()
        let scheduler = ReminderScheduler(center: center)
        let renewal = Date(timeIntervalSince1970: 1_800_000_000)
        try await scheduler.schedule(subscriptionId: UUID(), name: "X", renewal: renewal, daysBefore: 3)
        let req = try #require(center.addedRequests.first)
        let trigger = req.trigger as? UNCalendarNotificationTrigger
        let fire = trigger?.nextTriggerDate()
        let expected = Calendar.current.date(byAdding: .day, value: -3, to: renewal)
        #expect(fire.map { abs($0.timeIntervalSince(expected!)) < 1 } ?? false)
    }

    @Test("取消按 identifier 删除")
    func cancel() async throws {
        let center = MockNotificationCenter()
        let scheduler = ReminderScheduler(center: center)
        let id = UUID()
        try await scheduler.schedule(subscriptionId: id, name: "X",
                                     renewal: Date(timeIntervalSinceNow: 86400 * 10), daysBefore: 3)
        scheduler.cancel(subscriptionId: id)
        #expect(center.removedIdentifiers == [ReminderScheduler.identifier(for: id)])
    }
}

final class MockNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
    let granted: Bool
    let failOnAdd: Bool
    var requestAuthorizationCallCount = 0
    var addedRequests: [UNNotificationRequest] = []
    var removedIdentifiers: [String] = []

    private let lock = NSLock()

    init(granted: Bool = true, failOnAdd: Bool = false) {
        self.granted = granted
        self.failOnAdd = failOnAdd
    }

    func requestAuthorization() async throws -> Bool {
        lock.withLock { requestAuthorizationCallCount += 1 }
        return granted
    }
    func add(_ request: UNNotificationRequest) async throws {
        if failOnAdd { throw MockNotificationError.addFailed }
        lock.withLock { addedRequests.append(request) }
    }
    func removePendingNotificationRequests(withIdentifiers ids: [String]) {
        lock.withLock { removedIdentifiers.append(contentsOf: ids) }
    }
}

enum MockNotificationError: LocalizedError {
    case addFailed

    var errorDescription: String? { "mock notification add failed" }
}
