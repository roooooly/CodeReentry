import Testing
import Foundation
import SwiftData
import DevHubCore
@testable import DevHub

@Suite("Onboarding Flow")
@MainActor
struct OnboardingViewTests {

    @Test("初始 step = welcome")
    func initialStep() {
        let flow = OnboardingFlow()
        #expect(flow.step == .welcome)
    }

    @Test("扫描候选 → 调用 ProjectScanner 并填 candidates，默认勾选 git 仓库")
    func scanFillsCandidates() async throws {
        let env = try OnboardingViewTests.makeOnboardingEnv()
        // 在 root 下造两个目录：a 有 .git，b 有 package.json（无 .git）
        // （空目录无 project signal 不会被 scanner 发现）
        let a = env.root.appendingPathComponent("projA")
        let b = env.root.appendingPathComponent("projB")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: a.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "{}".write(to: b.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let flow = OnboardingFlow()
        flow.projectsRoot = env.root.path
        await flow.scan(deps: env.deps)

        #expect(flow.candidates.count == 2)
        #expect(flow.step == .confirm)
        // 默认勾选带 .git 的
        let aCandidate = flow.candidates.first { $0.name == "projA" }
        #expect(aCandidate?.hasGit == true)
        #expect(flow.selectedCandidates.contains(aCandidate?.path ?? "") == true)
        let bCandidate = flow.candidates.first { $0.name == "projB" }
        #expect(bCandidate?.hasGit == false)
        #expect(flow.selectedCandidates.contains(bCandidate?.path ?? "") == false)
    }

    @Test("确认注册 → 批量 register 选中项")
    func confirmRegistersSelected() async throws {
        let env = try OnboardingViewTests.makeOnboardingEnv()
        let a = env.root.appendingPathComponent("projA")
        let b = env.root.appendingPathComponent("projB")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: a.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try "{}".write(to: b.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

        let flow = OnboardingFlow()
        flow.projectsRoot = env.root.path
        await flow.scan(deps: env.deps)

        // 只勾选 projA（b 之前没被默认勾选）
        let aPath = flow.candidates.first { $0.name == "projA" }?.path ?? ""
        flow.selectedCandidates = [aPath]
        try flow.confirmRegistration(deps: env.deps)

        let all = try env.ctx.fetch(FetchDescriptor<Project>())
        #expect(all.count == 1)
        #expect(all.first?.name == "projA")

        #expect(flow.step == .permissions)
        #expect(flow.registrationSummary?.registeredCount == 1)
        #expect(flow.registrationSummary?.alreadyRegisteredCount == 0)
        let registeredMessage = String(
            format: String(localized: "新注册 %d 个项目"),
            locale: .current,
            1
        )
        #expect(flow.registrationSummary?.message.contains(registeredMessage) == true)
    }

    @Test("没有候选或未勾选项目时可以跳过并继续")
    func confirmAllowsSkippingRegistration() throws {
        let env = try OnboardingViewTests.makeOnboardingEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let flow = OnboardingFlow()
        flow.projectsRoot = env.root.path
        flow.candidates = []
        flow.selectedCandidates = []

        try flow.confirmRegistration(deps: env.deps)

        #expect(try env.ctx.fetch(FetchDescriptor<Project>()).isEmpty)
        #expect(flow.step == .permissions)
        let settings = try #require(env.ctx.fetch(FetchDescriptor<AppSettings>()).first)
        #expect(settings.projectsRoot == (env.root.path as NSString).standardizingPath)
    }

    @Test("批量注册跳过身份重复的归档副本并继续处理其他项目")
    func confirmSkipsIdentityConflictAndContinues() throws {
        let env = try OnboardingViewTests.makeOnboardingEnv()
        defer { try? FileManager.default.removeItem(at: env.root) }
        let live = env.root.appendingPathComponent("live")
        let archivedCopy = env.root.appendingPathComponent("archived-copy")
        let fresh = env.root.appendingPathComponent("fresh")
        for directory in [live, archivedCopy, fresh] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let sharedStableId = "shared-project-id"
        _ = try PathLocator.ensureDevHub(at: live, stableId: sharedStableId)
        _ = try PathLocator.ensureDevHub(at: archivedCopy, stableId: sharedStableId)
        _ = try env.deps.projectRegistry(in: env.ctx).register(
            name: "live", path: live.path, stableId: sharedStableId
        )

        let flow = OnboardingFlow()
        flow.projectsRoot = env.root.path
        flow.candidates = [
            OnboardingCandidate(path: archivedCopy.path, name: "archived-copy", hasGit: true),
            OnboardingCandidate(path: fresh.path, name: "fresh", hasGit: true)
        ]
        flow.selectedCandidates = [archivedCopy.path, fresh.path]

        try flow.confirmRegistration(deps: env.deps)

        let projects = try env.ctx.fetch(FetchDescriptor<Project>())
        #expect(projects.map(\.name).sorted() == ["fresh", "live"])
        #expect(flow.step == .permissions)
        #expect(flow.registrationSummary?.registeredCount == 1)
        #expect(flow.registrationSummary?.identityConflictNames == ["archived-copy"])
        #expect(flow.registrationSummary?.hasSkippedCandidates == true)
        let identityConflictMessage = String(
            format: String(localized: "跳过 %d 个身份重复目录：%@"),
            locale: .current,
            1,
            "archived-copy"
        )
        #expect(flow.registrationSummary?.message.contains(identityConflictMessage) == true)
        #expect(flow.registrationSummary?.message.contains("identityConflictNames") == false)
    }

    @Test("完成 → 写 onboardingCompleted=true 并触发回调")
    func completeSetsFlag() throws {
        let suiteName = "io.github.roooooly.devhub.tests.onboarding-complete.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        preferences.removePersistentDomain(forName: suiteName)
        defer { preferences.removePersistentDomain(forName: suiteName) }

        let env = try OnboardingViewTests.makeOnboardingEnv(preferences: preferences)
        let flow = OnboardingFlow()
        var completed = false
        flow.complete(deps: env.deps, onComplete: { completed = true })

        #expect(completed == true)
        #expect(env.deps.onboardingCompleted == true)
        #expect(preferences.bool(forKey: "devhub.onboarding.completed") == true)
    }

    // MARK: - env

    struct OnboardingEnv {
        let container: ModelContainer
        let ctx: ModelContext
        let deps: AppDependencies
        let root: URL
    }

    static func makeOnboardingEnv(preferences: UserDefaults = .standard) throws -> OnboardingEnv {
        let container = try ModelContainer(
            for: Project.self, Tool.self, Subscription.self,
                 PlatformAccount.self, ProjectPlatformBinding.self,
                 SessionIndex.self, AppSettings.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devhub-onb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let deps = AppDependencies(modelContainer: container, preferences: preferences)
        // 真实 ProjectScanner，但 rootURL 固定到临时 root（factory 忽略入参）
        deps.overrideServices(scannerFactory: { _ in ProjectScanner(rootURL: root) })

        return OnboardingEnv(container: container, ctx: container.mainContext, deps: deps, root: root)
    }
}
