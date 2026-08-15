import Foundation

/// Sparkle feed 配置（§8.3）。从 Info.plist 读取 SUFeedURL 等键。
/// `@unchecked Sendable`：infoDict 含 Any（plist 值），实践中只读。
public struct SparkleUpdaterConfig: @unchecked Sendable, Equatable {
    public let infoDict: [String: Any]

    public init(infoDict: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        self.infoDict = infoDict
    }

    public var feedURL: URL? {
        (infoDict["SUFeedURL"] as? String).flatMap(URL.init(string:))
    }

    /// 默认 true（spec §8.3），除非显式设 NO/false。
    public var enableInstallerLauncherService: Bool {
        if let v = infoDict["SUEnableInstallerLauncherService"] as? Bool { return v }
        if let s = infoDict["SUEnableInstallerLauncherService"] as? String { return s.lowercased() != "false" && s.lowercased() != "no" }
        return true
    }

    public static func == (lhs: SparkleUpdaterConfig, rhs: SparkleUpdaterConfig) -> Bool {
        lhs.feedURL == rhs.feedURL
            && lhs.enableInstallerLauncherService == rhs.enableInstallerLauncherService
    }
}

/// 把 Sparkle 抽象成协议，便于测试调度逻辑而不触发真实网络（§8.3）。
public protocol SparkleDriver: AnyObject, Sendable {
    func checkForUpdates() async
    func setAutomaticallyChecks(_ value: Bool, interval: TimeInterval) async
}

/// Sparkle 更新调度（§8.3）。feedURL 未配置时静默跳过所有 check。
@MainActor
public final class SparkleUpdater {
    public let driver: SparkleDriver
    public let config: SparkleUpdaterConfig
    public private(set) var lastCheckCallCount = 0

    public init(driver: SparkleDriver, config: SparkleUpdaterConfig) {
        self.driver = driver
        self.config = config
    }

    public func checkForUpdates() async {
        guard config.feedURL != nil else { return }  // 无 feed URL 静默跳过
        await driver.checkForUpdates()
        lastCheckCallCount += 1
    }

    public func setAutomaticallyChecksUpdates(_ value: Bool, interval: TimeInterval) async {
        await driver.setAutomaticallyChecks(value, interval: interval)
    }
}
