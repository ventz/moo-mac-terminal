//
//  UpdatePolicyTests.swift
//  MooTests
//

import Testing
@testable import Moo

struct UpdatePolicyTests {
    private let feed = "https://example.com/appcast.xml"

    @Test func permitsReleaseBundle() {
        #expect(UpdatePolicy.permitsUpdates(
            bundleIdentifier: "net.vpetkov.Moo",
            bundleNames: ["Moo"],
            feedURL: feed
        ))
    }

    @Test func rejectsDebugBundleIdentifier() {
        #expect(!UpdatePolicy.permitsUpdates(
            bundleIdentifier: "net.vpetkov.Moo.debug",
            bundleNames: ["Moo"],
            feedURL: feed
        ))
    }

    @Test func rejectsDebugBundleName() {
        #expect(!UpdatePolicy.permitsUpdates(
            bundleIdentifier: "net.vpetkov.Moo",
            bundleNames: ["Moo Debug"],
            feedURL: feed
        ))
    }

    /// Moo ships without an appcast. Without this, Sparkle would inherit
    /// upstream's feed and install the upstream app over the fork.
    @Test func rejectsMissingFeedURL() {
        #expect(!UpdatePolicy.permitsUpdates(
            bundleIdentifier: "net.vpetkov.Moo",
            bundleNames: ["Moo"],
            feedURL: nil
        ))
    }

    @Test func rejectsBlankFeedURL() {
        #expect(!UpdatePolicy.permitsUpdates(
            bundleIdentifier: "net.vpetkov.Moo",
            bundleNames: ["Moo"],
            feedURL: "   "
        ))
    }
}
