import Testing
import Foundation
@testable import DevHubCore

@Suite("Logger")
struct LoggerTests {

    @Test("subsystem and category are correct")
    func subsystemCategory() {
        #expect(AppLog.subsystem == "io.github.roooooly.devhub")
        #expect(AppLog.sessionReader.category == "session-reader")
        #expect(AppLog.process.category == "process")
        #expect(AppLog.lifecycle.category == "lifecycle")
        #expect(AppLog.fsEvent.category == "fs-event")
        #expect(AppLog.mcp.category == "mcp")
    }

    @Test("LogPrivacy has the three required levels")
    func privacyLevels() {
        #expect(LogPrivacy.public.redacted == false)
        #expect(LogPrivacy.private.redacted == true)
        #expect(LogPrivacy.sensitive.redacted == true)
        #expect(LogPrivacy.sensitive.isSensitive == true)
        #expect(LogPrivacy.private.isSensitive == false)
    }

    @Test("redact applies masking per level")
    func redactPerLevel() {
        let secret = "AKIAIOSFODNN7EXAMPLE"
        #expect(LogPrivacy.public.redact(secret) == secret)
        #expect(LogPrivacy.private.redact(secret) == "<private>")
        #expect(LogPrivacy.sensitive.redact(secret) == "<sensitive>")
    }

    @Test("redact empty string still returns marker for private/sensitive")
    func redactEmpty() {
        #expect(LogPrivacy.private.redact("") == "<private>")
        #expect(LogPrivacy.sensitive.redact("") == "<sensitive>")
        #expect(LogPrivacy.public.redact("") == "")
    }

    @Test("LoggedValue records value and privacy")
    func loggedValue() {
        let v = LoggedValue("AKIA...", privacy: .sensitive)
        #expect(v.privacy == .sensitive)
        #expect(v.redacted() == "<sensitive>")
        let p = LoggedValue("/Users/example/Projects/ExampleApp", privacy: .public)
        #expect(p.redacted() == "/Users/example/Projects/ExampleApp")
    }

    @Test("AppLogger.format returns interpolated string with redaction")
    func formatInterpolates() {
        let line = AppLogger.format(
            "opening tool \(LoggedValue("codex", privacy: .public)) with arg \(LoggedValue("secret-token", privacy: .sensitive))",
            level: .info
        )
        #expect(line.contains("codex"))
        #expect(line.contains("<sensitive>"))
        #expect(line.contains("[info]"))
    }
}
