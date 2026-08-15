import AppKit
import OSLog

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "menubar")

@MainActor
final class MenuBarController {
    static let projectsChangedNotification = Notification.Name("DevHubProjectsChanged")

    let viewModel: MenuBarViewModel
    private(set) var statusItem: NSStatusItem?
    var onSelectProject: ((String) -> Void)?  // stableId
    var onShowApp: (() -> Void)?
    private let notificationCenter: NotificationCenter
    /// `deinit` is nonisolated in Swift 6. The token is only created/removed here and
    /// the callback immediately hops back to MainActor, so this explicit escape is scoped.
    nonisolated(unsafe) private var projectsChangedObserver: NSObjectProtocol?

    init(
        viewModel: MenuBarViewModel,
        notificationCenter: NotificationCenter = .default
    ) {
        self.viewModel = viewModel
        self.notificationCenter = notificationCenter
        projectsChangedObserver = notificationCenter.addObserver(
            forName: Self.projectsChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAndRebuild()
            }
        }
    }

    deinit {
        if let projectsChangedObserver {
            notificationCenter.removeObserver(projectsChangedObserver)
        }
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let img = NSImage(systemSymbolName: "hammer.fill", accessibilityDescription: "DevHub")
        item.button?.image = img
        item.button?.imagePosition = .imageOnly
        statusItem = item
        rebuild()
        Task {
            await refreshAndRebuild()
        }
    }

    func refreshAndRebuild() async {
        await viewModel.refresh()
        rebuild()
    }

    func rebuild() {
        statusItem?.menu = buildMenu()
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        if let active = viewModel.activeProjectName {
            menu.addItem(withTitle: String(localized: "当前活跃项目：\(active)"), action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        let recent = NSMenuItem(title: String(localized: "最近项目"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        if viewModel.recentProjects.isEmpty {
            submenu.addItem(withTitle: String(localized: "（无）"), action: nil, keyEquivalent: "")
        } else {
            for p in viewModel.recentProjects {
                let item = submenu.addItem(withTitle: p.name, action: #selector(openProject(_:)), keyEquivalent: "")
                item.representedObject = p.stableId
                item.target = self
            }
        }
        recent.submenu = submenu
        menu.addItem(recent)
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "打开 DevHub"), action: #selector(showApp), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "退出 DevHub"), action: #selector(quitApp), keyEquivalent: "q")
        return menu
    }

    @objc func openProject(_ sender: NSMenuItem) {
        guard let stableId = sender.representedObject as? String else { return }
        logger.info("menubar openProject stableId=\(stableId, privacy: .public)")
        onSelectProject?(stableId)
        presentApp()
    }

    @objc func showApp() { presentApp() }
    @objc func quitApp() { NSApp.terminate(nil) }

    private func presentApp() {
        if let onShowApp {
            onShowApp()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
