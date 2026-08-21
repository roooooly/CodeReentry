import SwiftUI

/// Value-only presentation state so launch errors never retain model objects or
/// accidentally place command arguments and environment values in the UI.
struct TerminalLaunchFailure: Equatable {
    let message: String
    let launcherPath: String?

    init(_ error: any Error) {
        message = error.localizedDescription
        launcherPath = (error as? TerminalLaunchError)?.recoveryLauncherPath
    }
}

private struct TerminalLaunchRecoveryAlertModifier: ViewModifier {
    @Environment(AppDependencies.self) private var deps
    @Binding var failure: TerminalLaunchFailure?
    let fallbackTitle: String
    let onCommandCopied: @MainActor () -> Void

    func body(content: Content) -> some View {
        content.alert(
            failure?.launcherPath == nil
                ? fallbackTitle
                : String(localized: "无法自动打开 Terminal"),
            isPresented: Binding(
                get: { failure != nil },
                set: { isPresented in
                    guard !isPresented else { return }
                    // Escape/window dismissal is a cancel action. Remove the
                    // owner-only launcher instead of leaving its environment on disk.
                    if let path = failure?.launcherPath {
                        deps.discardTerminalFallback(launcherPath: path)
                    }
                    failure = nil
                }
            )
        ) {
            if let launcherPath = failure?.launcherPath {
                Button(String(localized: "复制一次性命令")) {
                    deps.copyTerminalFallbackCommand(launcherPath: launcherPath)
                    // Clear first so SwiftUI's subsequent presentation update cannot
                    // interpret the successful copy action as a discard.
                    failure = nil
                    onCommandCopied()
                }
                Button(String(localized: "丢弃命令"), role: .cancel) {
                    deps.discardTerminalFallback(launcherPath: launcherPath)
                    failure = nil
                }
            } else {
                Button(String(localized: "好")) { failure = nil }
            }
        } message: {
            Text(failure?.message ?? "")
        }
    }
}

extension View {
    func terminalLaunchRecoveryAlert(
        failure: Binding<TerminalLaunchFailure?>,
        fallbackTitle: String,
        onCommandCopied: @escaping @MainActor () -> Void
    ) -> some View {
        modifier(TerminalLaunchRecoveryAlertModifier(
            failure: failure,
            fallbackTitle: fallbackTitle,
            onCommandCopied: onCommandCopied
        ))
    }
}
