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
    let sessionCount: Int
    var id: String { path }

    init(path: String, name: String, hasGit: Bool, sessionCount: Int = 0) {
        self.path = path
        self.name = name
        self.hasGit = hasGit
        self.sessionCount = sessionCount
    }
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
    private(set) var isScanningSessions = false
    private(set) var sessionScanError: String?
    private(set) var isDiscoveringSessionProjects = false
    private(set) var discoveredProjectsFromSessions = false
    private(set) var discoveredSessionCount = 0
    private(set) var linkedSessionCount = 0
    private(set) var isRegisteringProjects = false

    func goToPickRoot() { step = .pickRoot }
    func goToWelcome() { step = .welcome }

    func scan(deps: AppDependencies) async {
        step = .scanning
        registrationSummary = nil
        discoveredProjectsFromSessions = false
        discoveredSessionCount = 0
        linkedSessionCount = 0
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

    /// Explicit, privacy-safe fast path: index bounded local session metadata first, then
    /// infer project roots from reader-provided cwd values. The user still confirms every
    /// candidate before registration.
    func discoverProjectsFromSessions(
        deps: AppDependencies,
        operation: @MainActor () async throws -> Void
    ) async {
        guard !isDiscoveringSessionProjects else { return }
        step = .scanning
        registrationSummary = nil
        scanError = nil
        discoveredProjectsFromSessions = true
        discoveredSessionCount = 0
        linkedSessionCount = 0
        isDiscoveringSessionProjects = true
        defer { isDiscoveringSessionProjects = false }

        var aggregationError: String?
        do {
            try await operation()
        } catch {
            // The aggregator commits successful readers before reporting partial failures.
            // Keep those useful results visible and explain the incomplete source separately.
            aggregationError = error.localizedDescription
        }

        var descriptor = FetchDescriptor<SessionIndex>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        let readContext = ModelContext(deps.modelContainer)
        readContext.autosaveEnabled = false
        let sessions = (try? readContext.fetch(descriptor)) ?? []
        var orderedPaths: [String] = []
        var countsByPath: [String: Int] = [:]
        var inferredPathsByCwd: [String: String] = [:]
        var rejectedCwds: Set<String> = []
        let candidateLimit = 20

        for session in sessions where !session.projectCwd.isEmpty {
            let path: String
            if let cached = inferredPathsByCwd[session.projectCwd] {
                path = cached
            } else {
                guard !rejectedCwds.contains(session.projectCwd) else { continue }
                guard let inferred = Self.inferredProjectPath(from: session.projectCwd) else {
                    rejectedCwds.insert(session.projectCwd)
                    continue
                }
                inferredPathsByCwd[session.projectCwd] = inferred
                path = inferred
            }
            if countsByPath[path] == nil {
                guard orderedPaths.count < candidateLimit else { continue }
                orderedPaths.append(path)
                countsByPath[path] = 0
            }
            countsByPath[path, default: 0] += 1
        }

        candidates = orderedPaths.map { path in
            OnboardingCandidate(
                path: path,
                name: URL(fileURLWithPath: path).lastPathComponent,
                hasGit: FileManager.default.fileExists(atPath: path + "/.git"),
                sessionCount: countsByPath[path, default: 0]
            )
        }
        selectedCandidates = Set(candidates.map(\.path))
        discoveredSessionCount = candidates.reduce(0) { $0 + $1.sessionCount }
        scanError = aggregationError
        step = .confirm
    }

    func confirmRegistration(deps: AppDependencies) async throws {
        guard !isRegisteringProjects else { return }
        isRegisteringProjects = true
        defer { isRegisteringProjects = false }
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
        if discoveredProjectsFromSessions,
           summary.registeredCount + summary.alreadyRegisteredCount > 0 {
            let writer = SessionIndexWriter(modelContainer: deps.modelContainer)
            linkedSessionCount = try await writer.linkUnclassifiedSessionsToRegisteredProjects()
        } else if discoveredProjectsFromSessions {
            // Do not claim that the fast path succeeded when the user skipped every
            // candidate or every selected directory was unavailable.
            discoveredProjectsFromSessions = false
        }
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

    /// 用户在引导末页明确选择后，才执行一次会话增量扫描。失败时不把引导标记为
    /// 已完成，让用户可以重试或明确选择“暂不扫描”。
    func scanSessionsAndComplete(
        deps: AppDependencies,
        operation: @MainActor () async throws -> Void,
        onComplete: () -> Void
    ) async {
        guard !isScanningSessions else { return }
        isScanningSessions = true
        sessionScanError = nil
        defer { isScanningSessions = false }

        do {
            try await operation()
            complete(deps: deps, onComplete: onComplete)
        } catch {
            sessionScanError = error.localizedDescription
        }
    }

    func complete(deps: AppDependencies, onComplete: () -> Void) {
        deps.onboardingCompleted = true
        onComplete()
    }

    private static func inferredProjectPath(from cwd: String) -> String? {
        let fileManager = FileManager.default
        let standardized = (cwd as NSString).standardizingPath
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }

        let original = URL(fileURLWithPath: standardized, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let home = fileManager.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard original.path != "/", original.path != home.path else { return nil }

        var current = original
        var nearestManifestRoot: URL?
        while current.path != "/" {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current.path
            }
            if nearestManifestRoot == nil,
               containsManifestSignal(at: current, fileManager: fileManager) {
                nearestManifestRoot = current
            }
            if current.path == home.path { break }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { break }
            current = parent
        }
        return nearestManifestRoot?.path ?? original.path
    }

    private static func containsManifestSignal(at directory: URL, fileManager: FileManager) -> Bool {
        let markers = ["package.json", "Cargo.toml", "go.mod", "pyproject.toml"]
        if markers.contains(where: {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) {
            return true
        }
        let children = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return children.contains { $0.pathExtension == "xcodeproj" }
    }
}
