import Foundation
import Sparkle
import DevHubCore

/// 生产实现：桥接到 Sparkle 的 SPUStandardUpdaterController（§8.3）。
@MainActor
final class SparkleProductionDriver: SparkleDriver {
    private let controller: SPUStandardUpdaterController

    init() throws {
        // Sparkle 从 Info.plist 读取 SUFeedURL；App 只会在该键有效时构造 driver。
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() async {
        controller.updater.checkForUpdates()
    }

    func setAutomaticallyChecks(_ value: Bool, interval: TimeInterval) async {
        controller.updater.automaticallyChecksForUpdates = value
        controller.updater.updateCheckInterval = interval
    }
}
