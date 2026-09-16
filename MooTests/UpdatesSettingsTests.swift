import Foundation
import Testing
@testable import Moo

@MainActor
struct UpdatesSettingsTests {
    @Test func lastCheckedReadsNeverBeforeTheFirstCheck() {
        #expect(UpdatesSettingsView.lastCheckedText(nil) == "Never")
        #expect(UpdatesSettingsView.lastCheckedText(Date(timeIntervalSince1970: 0)) != "Never")
    }

    @Test func releaseBuildsCheckAutomaticallyWithoutAsking() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Moo/Info.plist")
        let info = try #require(NSDictionary(contentsOf: plist))
        #expect(info["SUEnableAutomaticChecks"] as? Bool == true)
    }
}
