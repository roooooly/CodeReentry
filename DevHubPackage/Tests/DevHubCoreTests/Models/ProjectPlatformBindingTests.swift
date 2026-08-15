import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("ProjectPlatformBinding model")
struct ProjectPlatformBindingTests {

    @Test("binding tracks per-(project, account) publish state")
    @MainActor
    func perComboState() throws {
        let container = try ModelContainer(
            for: Project.self, PlatformAccount.self, ProjectPlatformBinding.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let project = Project(stableId: "s1", name: "ExampleApp", path: "/tmp/ExampleApp")
        let account = PlatformAccount(platform: .twitter, displayName: "@example", loginUrl: "https://x.com")
        let binding = ProjectPlatformBinding(
            project: project,
            account: account,
            publishStatus: .published,
            publishUrl: "https://x.com/example/status/1"
        )
        ctx.insert(project); ctx.insert(account); ctx.insert(binding)
        try ctx.save()

        let fetched = try ctx.fetch(FetchDescriptor<ProjectPlatformBinding>()).first!
        #expect(fetched.publishStatus == .published)
        #expect(fetched.publishUrl == "https://x.com/example/status/1")
        #expect(fetched.project?.stableId == "s1")
        #expect(fetched.account?.displayName == "@example")
    }

    @Test("publish status enum cases")
    func publishStatusCases() {
        #expect(PublishStatus.allCases.count == 4)
        #expect(PublishStatus.allCases.contains(.inReview))
    }
}
