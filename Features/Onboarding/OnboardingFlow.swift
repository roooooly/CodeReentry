import Foundation
import SwiftData
import OSLog
import DevHubCore

private let logger = Logger(subsystem: "io.github.roooooly.devhub", category: "onboarding")

/// 扫描候选项（UI 端视图模型，从 Core ScannedProject 映射而来）
struct OnboardingCandidate: Identifiable, Hashable {
    let path: String
    let name: String
    let hasGit: Bool
    var id: String { path }
}

struct OnboardingRegistrationSummary: Equatable {
    var registeredCount = 0
    var alreadyRegisteredCount = 0
    var identityConflictNames: [String] = []
    var unavailableNames: [String] = []

    var hasSkippedCandidates: Bool {
        !identityConflictNames.isEmpty || !unavailableNames.isEmpty
    }

    var message: String {
        var parts = [
            String(
                format: String(localized: "新注册 %d 个项目"),
                locale: .current,
                registeredCount
            ),
            String(
                format: String(localized: "已有 %d 个"),
                locale: .current,
                alreadyRegisteredCount
            )
        ]
        if !identityConflictNames.isEmpty {
            parts.append(String(
                format: String(localized: "跳过 %d 个身份重复目录：%@"),
                locale: .current,
                identityConflictNames.count,
                identityConflictNames.joined(separator: "、")
            ))
        }
        if !unavailableNames.isEmpty {
            parts.append(String(
                format: String(localized: "跳过 %d 个已不可用目录：%@"),
                locale: .current,
                unavailableNames.count,
                unavailableNames.joined(separator: "、")
            ))
        }
        return parts.joined(separator: "；") + "。"
    }
}

@Observable
@MainActor
final class OnboardingFlow {
    enum Step: Int { case welcome, pickRoot, scanning, confirm, intro, permissions }

    var step: Step = .welcome
    var projectsRoot: String = "~/Projects"
    var candidates: [OnboardingCandidate] = []
    var selectedCandidates: Set<String> = []  // 存 path
    var scanError: String?
    var registrationSummary: OnboardingRegistrationSummary?

    func goToPickRoot() { step = .pickRoot }
    func goToWelcome() { step = .welcome }

    func scan(deps: AppDependencies) async {
        step = .scanning
        registrationSummary = nil
        do {
            let expanded = NSString(string: projectsRoot).expandingTildeInPath
            let rootURL = URL(fileURLWithPath: expanded)
            let scanned = try deps.projectScanner(rootURL: rootURL).scan()
            candidates = scanned.map {
                OnboardingCandidate(
                    path: $0.url.path,
                    name: $0.url.lastPathComponent,
                    hasGit: $0.signals.contains(.git)
                )
            }
            // 默认勾选 git 仓库
            selectedCandidates = Set(candidates.filter(\.hasGit).map(\.path))
            scanError = nil
            step = .confirm
        } catch {
            scanError = error.localizedDescription
            step = .confirm  // 让用户看到错误并可重试
        }
    }

    func confirmRegistration(deps: AppDependencies) throws {
        let ctx = deps.modelContainer.mainContext
        let registry = deps.projectRegistry(in: ctx)
        let expandedRoot = (projectsRoot as NSString).expandingTildeInPath
        var summary = OnboardingRegistrationSummary()
        for candidate in candidates where selectedCandidates.contains(candidate.path) {
            // 跳过已注册（按 path）
            let path = (candidate.path as NSString).standardizingPath
            let existing = try ctx.fetch(FetchDescriptor<Project>(predicate: #Predicate { $0.path == path }))
            if !existing.isEmpty {
                summary.alreadyRegisteredCount += 1
                continue
            }
            do {
                _ = try registry.register(
                    name: candidate.name, path: path, stableId: UUID().uuidString
                )
                summary.registeredCount += 1
            } catch ProjectRegistryError.duplicatePath {
                // A concurrent registration or path alias is already represented.
                summary.alreadyRegisteredCount += 1
            } catch ProjectRegistryError.duplicateStableId {
                // Archive/copy directories can share `.devhub/project.local.json`
                // with the live project. Registering both would corrupt identity,
                // so skip only that candidate instead of aborting the whole batch.
                summary.identityConflictNames.append(candidate.name)
            } catch ProjectRegistryError.invalidPath {
                // The directory may have moved between scan and confirmation.
                summary.unavailableNames.append(candidate.name)
            }
        }
        let settings = try deps.ensureAppSettings(in: ctx)
        settings.projectsRoot = (expandedRoot as NSString).standardizingPath
        try ctx.save()
        NotificationCenter.default.post(
            name: Notification.Name("DevHubProjectsChanged"),
            object: nil
        )
        registrationSummary = summary
        scanError = nil
        logger.info(
            "批量注册 \(summary.registeredCount) 个项目，已有 \(summary.alreadyRegisteredCount) 个，身份冲突 \(summary.identityConflictNames.count) 个"
        )
        step = .permissions
    }

    func goToIntro() { step = .intro }

    func complete(deps: AppDependencies, onComplete: () -> Void) {
        deps.onboardingCompleted = true
        onComplete()
    }
}
