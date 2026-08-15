import Testing
@testable import DevHubCore

@Suite("Package init")
struct PackageInitTests {
    @Test("version is exposed")
    func versionExposed() {
        #expect(DevHubCoreVersion.current == "0.1.0")
    }
}
