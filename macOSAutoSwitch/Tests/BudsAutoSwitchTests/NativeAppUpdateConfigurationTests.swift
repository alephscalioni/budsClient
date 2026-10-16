import Foundation
import XCTest
@testable import BudsAutoSwitch

final class NativeAppUpdateConfigurationTests: XCTestCase {
    func testDismissedDownloadDoesNotScheduleInstallButInstallingStageDoes() {
        typealias Intent = NativeAppUpdateInstallationIntent
        var state = Intent()
        XCTAssertFalse(state.pending)
        state.choose(.install, stage: .notDownloaded)
        XCTAssertFalse(state.pending, "Starting a download is not installing on quit")
        state.choose(.dismiss, stage: .downloaded)
        XCTAssertFalse(state.pending, "Sparkle retains this download without scheduling it")
        state.schedule()
        state.choose(.dismiss, stage: .installing)
        XCTAssertTrue(state.pending, "Dismissing a prepared installation still installs on quit")
        state.choose(.skip, stage: .installing)
        XCTAssertFalse(state.pending)
        state.choose(.install, stage: .downloaded)
        XCTAssertTrue(state.pending)
        state.cancel()
        XCTAssertFalse(state.pending)
    }
    private let feed = "https://updates.budsapp.dev/appcast.xml"
    private let key = Data((0..<32).map(UInt8.init)).base64EncodedString()

    private func read(feed: String? = nil, key: String? = nil) throws -> NativeAppUpdateConfiguration? {
        try NativeAppUpdateConfiguration.read(info: ["SUFeedURL": feed ?? self.feed, "SUPublicEDKey": key ?? self.key])
    }

    func testMissingConfigurationIsUnconfigured() throws {
        XCTAssertNil(try NativeAppUpdateConfiguration.read(info: [:]))
        XCTAssertNil(try NativeAppUpdateConfiguration.read(info: ["CFBundleVersion": "12", "SUEnableAutomaticChecks": true]))
    }

    func testRequiresBothSettingsAndRejectsWrongTypes() {
        let configurations: [[String: Any]] = [
            ["SUFeedURL": feed], ["SUPublicEDKey": key],
            ["SUFeedURL": "", "SUPublicEDKey": key], ["SUFeedURL": feed, "SUPublicEDKey": ""],
            ["SUFeedURL": 42, "SUPublicEDKey": key], ["SUFeedURL": feed, "SUPublicEDKey": true],
            ["SUFeedURL": NSNull(), "SUPublicEDKey": NSNull()]
        ]
        for info in configurations { XCTAssertThrowsError(try NativeAppUpdateConfiguration.read(info: info)) }
    }

    func testValidHTTPSFeedAnd32BytePublicKey() throws {
        let config = try XCTUnwrap(read())
        XCTAssertEqual(config.feedURL.absoluteString, feed)
        XCTAssertEqual(config.publicEDKey, key)
        XCTAssertEqual(Data(base64Encoded: config.publicEDKey)?.count, 32)
    }

    func testAllowsIndependentNativeReleaseFeedAndEncodedPath() throws {
        for feed in [
            "https://github.com/aleph/GalaxyBudsClient/releases/download/native/appcast.xml",
            "https://updates.budsapp.dev/releases%20stable/appcast.xml",
            "https://updates.budsapp.dev:8443/appcast.xml"
        ] {
            XCTAssertNotNil(try read(feed: feed), feed)
        }
    }

    func testRejectsInsecureRelativeMalformedAndCredentialBearingURLs() {
        for feed in [
            "http://updates.budsapp.dev/appcast.xml", "file:///tmp/appcast.xml",
            "ftp://updates.budsapp.dev/appcast.xml", "/appcast.xml", "//updates.budsapp.dev/appcast.xml",
            "https:///appcast.xml", "https://", "https://updates..budsapp.dev/appcast.xml",
            "https://-updates.budsapp.dev/appcast.xml", "https://updates.budsapp.dev:0/appcast.xml",
            "https://updates.budsapp.dev:65536/appcast.xml", "https://user:secret@updates.budsapp.dev/appcast.xml",
            "https://user@updates.budsapp.dev/appcast.xml", "https://updates.budsapp.dev/feed?token=secret",
            "https://updates.budsapp.dev/feed#fragment", "https://updates.budsapp.dev/app cast.xml",
            "https://updates.budsapp.dev/%zz", "https://updates.budsapp.dev/%0D%0Afeed",
            "https://updates.budsapp.dev/%5Cfeed", "https://updates.budsapp.dev/feed\n",
            " https://updates.budsapp.dev/feed", "https://updates.budsapp.dev\\@elsewhere.dev/feed"
        ] {
            XCTAssertThrowsError(try read(feed: feed), feed)
        }
    }

    func testRejectsPlaceholderAndLocalURLsIncludingEncodedTemplates() {
        for feed in [
            "https://example.com/appcast.xml", "https://updates.example.org/appcast.xml",
            "https://example.net/appcast.xml", "https://updates.invalid/feed", "https://updates.test/feed",
            "https://localhost/feed", "https://updates.local/feed", "https://127.0.0.1/feed",
            "https://[::1]/feed", "https://YOUR-DOMAIN.dev/appcast.xml",
            "https://updates.budsapp.dev/REPLACE_ME/appcast.xml", "https://updates.budsapp.dev/placeholder.xml",
            "https://updates.budsapp.dev/${CHANNEL}/appcast.xml", "https://updates.budsapp.dev/%7BCHANNEL%7D/feed",
            "https://updates.budsapp.dev/%3CFEED_URL%3E", "https://updates.budsapp.dev/__APPCAST__/feed"
        ] {
            XCTAssertThrowsError(try read(feed: feed), feed)
        }
    }

    func testRejectsUpstreamReleaseFeedsAndEquivalentEncodings() {
        for feed in [
            "https://github.com/timschneeb/GalaxyBudsClient/releases.atom",
            "https://github.com/timschneeb/GalaxyBudsClient/releases/latest/download/appcast.xml",
            "https://GITHUB.COM/TIMSCHNEEB/GALAXYBUDSCLIENT/releases",
            "https://api.github.com/repos/timschneeb/GalaxyBudsClient/releases",
            "https://raw.githubusercontent.com/timschneeb/GalaxyBudsClient/master/appcast.xml",
            "https://timschneeb.github.io/GalaxyBudsClient/appcast.xml",
            "https://github.com/%74imschneeb/Galaxy%42udsClient/releases.atom",
            "https://github.com/timschneeb/./GalaxyBudsClient/releases.atom",
            "https://github.com/timschneeb/unused/../GalaxyBudsClient/releases.atom"
        ] {
            XCTAssertThrowsError(try read(feed: feed), feed) { error in
                XCTAssertEqual(error as? NativeAppUpdateConfiguration.ConfigurationError, .upstreamFeed, feed)
            }
        }
    }

    func testRejectsMalformedNoncanonicalAndWrongLengthPublicKeys() {
        // A 32-byte encoding ends in one '='. Altering the low padding bits must not be accepted.
        var noncanonical = Array(key)
        noncanonical[noncanonical.count - 2] = "9"
        for key in [
            "not base64!", "\n" + self.key, self.key + "\n", String(self.key.dropLast()), String(noncanonical),
            Data(repeating: 7, count: 16).base64EncodedString(), Data(repeating: 7, count: 31).base64EncodedString(),
            Data(repeating: 7, count: 33).base64EncodedString(), Data(repeating: 7, count: 64).base64EncodedString()
        ] {
            XCTAssertThrowsError(try read(key: key), key)
        }
    }

    func testPreferenceActionsAcceptOnlyRealBooleans() throws {
        for action in ["app.update_automatic", "app.update_downloads"] {
            let expectedTrue: NativeAppUpdateAction = action == "app.update_automatic" ? .automatic(true) : .downloads(true)
            let expectedFalse: NativeAppUpdateAction = action == "app.update_automatic" ? .automatic(false) : .downloads(false)
            XCTAssertEqual(NativeAppUpdateAction.parse(["action": action, "enabled": true]), expectedTrue)
            XCTAssertEqual(NativeAppUpdateAction.parse(["action": action, "enabled": false]), expectedFalse)
            let json = try JSONSerialization.jsonObject(with: Data("{\"action\":\"\(action)\",\"enabled\":true}".utf8))
            XCTAssertEqual(NativeAppUpdateAction.parse(try XCTUnwrap(json as? [String: Any])), expectedTrue)
            let invalid: [Any] = [0, 1, NSNumber(value: 1), NSNumber(value: 0.0), "true", "false", "1", NSNull(), [Any]()]
            for value in invalid {
                XCTAssertNil(NativeAppUpdateAction.parse(["action": action, "enabled": value]), "\(action): \(value)")
            }
            XCTAssertNil(NativeAppUpdateAction.parse(["action": action]))
        }
        XCTAssertEqual(NativeAppUpdateAction.parse(["action": "app.update_check"]), .check)
        XCTAssertNil(NativeAppUpdateAction.parse([:]))
        XCTAssertNil(NativeAppUpdateAction.parse(["action": "app.update_unknown", "enabled": true]))
    }

    func testSafetyRequiresReadinessBothBeforeAndAfterGracefulShutdown() {
        typealias Policy = NativeAppUpdateSafetyPolicy
        XCTAssertEqual(Policy.nextStep(isSafe: false, shutdownPrepared: false, cancelled: false), .wait)
        XCTAssertEqual(Policy.nextStep(isSafe: true, shutdownPrepared: false, cancelled: false), .prepareShutdown)
        // A call/handoff can start during the async drain. Completion alone never permits install.
        XCTAssertEqual(Policy.nextStep(isSafe: false, shutdownPrepared: true, cancelled: false), .wait)
        XCTAssertEqual(Policy.nextStep(isSafe: true, shutdownPrepared: true, cancelled: false), .install)
        for safe in [false, true] {
            for prepared in [false, true] {
                XCTAssertEqual(Policy.nextStep(isSafe: safe, shutdownPrepared: prepared, cancelled: true), .cancelled)
            }
        }
    }
}
