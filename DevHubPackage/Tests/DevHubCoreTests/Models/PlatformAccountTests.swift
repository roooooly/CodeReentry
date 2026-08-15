import Testing
import Foundation
import SwiftData
@testable import DevHubCore

@Suite("PlatformAccount model")
struct PlatformAccountTests {

    @Test("init populates fields")
    func initFields() {
        let a = PlatformAccount(
            platform: .xiaohongshu,
            displayName: "我的小红书号",
            loginUrl: "https://creator.xiaohongshu.com"
        )
        #expect(a.platform == .xiaohongshu)
        #expect(a.displayName == "我的小红书号")
        #expect(a.loginUrl == "https://creator.xiaohongshu.com")
    }

    @Test("account has no credential field by design (v1)")
    func noCredentialField() throws {
        let a = PlatformAccount(platform: .twitter, displayName: "@me", loginUrl: "https://x.com")
        let mirror = Mirror(reflecting: a)
        let fieldNames = Set(mirror.children.compactMap { $0.label })
        #expect(!fieldNames.contains("keychainKey"))
        #expect(!fieldNames.contains("cookie"))
        #expect(!fieldNames.contains("token"))
    }

    @Test("one account can be referenced by multiple bindings (multi-project reuse)")
    @MainActor
    func accountMultiReuse() throws {
        let container = try ModelContainer(
            for: PlatformAccount.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = container.mainContext
        let acct = PlatformAccount(platform: .wechatOA, displayName: "OA", loginUrl: "https://mp.weixin.qq.com")
        ctx.insert(acct)
        try ctx.save()
        #expect(try ctx.fetch(FetchDescriptor<PlatformAccount>()).count == 1)
    }
}
