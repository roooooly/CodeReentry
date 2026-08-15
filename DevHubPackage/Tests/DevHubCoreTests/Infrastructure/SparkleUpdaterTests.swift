import Testing
import Foundation
@testable import DevHubCore

@Suite("SparkleUpdaterConfig")
struct SparkleUpdaterConfigTests {
    @Test("feedURL 从 SUFeedURL 读取")
    func feedURLFromPlist() {
        let cfg = SparkleUpdaterConfig(infoDict: ["SUFeedURL": "https://example.com/appcast.xml"])
        #expect(cfg.feedURL?.absoluteString == "https://example.com/appcast.xml")
    }

    @Test("无 SUFeedURL 返回 nil")
    func missingFeedURL() {
        let cfg = SparkleUpdaterConfig(infoDict: [:])
        #expect(cfg.feedURL == nil)
    }

    @Test("SUEnableInstallerLauncherService 默认 true")
    func installerLauncherServiceDefault() {
        let cfg = SparkleUpdaterConfig(infoDict: [:])
        #expect(cfg.enableInstallerLauncherService == true)
    }

    @Test("SUEnableInstallerLauncherService=NO 关闭")
    func installerLauncherServiceOff() {
        #expect(SparkleUpdaterConfig(infoDict: ["SUEnableInstallerLauncherService": "NO"]).enableInstallerLauncherService == false)
        #expect(SparkleUpdaterConfig(infoDict: ["SUEnableInstallerLauncherService": "false"]).enableInstallerLauncherService == false)
        #expect(SparkleUpdaterConfig(infoDict: ["SUEnableInstallerLauncherService": false]).enableInstallerLauncherService == false)
    }
}

@MainActor
@Suite("SparkleUpdater scheduling")
struct SparkleUpdaterSchedulingTests {

    final class StubDriver: SparkleDriver, @unchecked Sendable {
        private let lock = NSLock()
        private var _check = 0
        private var _auto = false
        private var _interval: TimeInterval = 0

        var checkCallCount: Int { lock.withLock { _check } }
        var automaticallyChecks: Bool { lock.withLock { _auto } }
        var updateCheckInterval: TimeInterval { lock.withLock { _interval } }

        func checkForUpdates() async { lock.withLock { _check += 1 } }
        func setAutomaticallyChecks(_ value: Bool, interval: TimeInterval) async {
            lock.withLock { _auto = value; _interval = interval }
        }
    }

    @Test("checkForUpdates 委托 driver（feedURL 已配置）")
    func checkDelegates() async {
        let driver = StubDriver()
        let cfg = SparkleUpdaterConfig(infoDict: ["SUFeedURL": "https://x/appcast.xml"])
        let updater = SparkleUpdater(driver: driver, config: cfg)
        await updater.checkForUpdates()
        #expect(driver.checkCallCount == 1)
        #expect(updater.lastCheckCallCount == 1)
    }

    @Test("setAutomaticallyChecksUpdates 委托 driver")
    func autoCheck() async {
        let driver = StubDriver()
        let updater = SparkleUpdater(driver: driver, config: SparkleUpdaterConfig(infoDict: [:]))
        await updater.setAutomaticallyChecksUpdates(true, interval: 86400)
        #expect(driver.automaticallyChecks == true)
        #expect(driver.updateCheckInterval == 86400)
    }

    @Test("feedURL 未配置时 check 静默跳过")
    func noCheckWithoutFeed() async {
        let driver = StubDriver()
        let updater = SparkleUpdater(driver: driver, config: SparkleUpdaterConfig(infoDict: [:]))
        await updater.checkForUpdates()
        #expect(driver.checkCallCount == 0)
        #expect(updater.lastCheckCallCount == 0)
    }
}
