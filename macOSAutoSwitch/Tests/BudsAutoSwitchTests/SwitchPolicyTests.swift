import XCTest
@testable import BudsAutoSwitch

final class SwitchPolicyTests: XCTestCase {
    func sample(mac: Bool = false, input: Bool = false, media: Bool = false, call: Bool = false, valid: Bool = true) -> ActivitySample {
        ActivitySample(macOutput: mac, macInput: input, phoneMedia: media, phoneCall: call, valid: valid)
    }
    func testStartingWithExistingPlaybackDoesNotSteal() {
        var policy = SwitchPolicy()
        XCTAssertNil(policy.evaluate(sample(mac: true), at: 0))
        XCTAssertNil(policy.evaluate(sample(mac: true), at: 100))
    }
    func testMacPlaybackIsDebouncedAndShortNotificationsIgnored() {
        var policy = SwitchPolicy()
        XCTAssertNil(policy.evaluate(sample(), at: 0))
        XCTAssertNil(policy.evaluate(sample(mac: true), at: 1))
        XCTAssertNil(policy.evaluate(sample(), at: 1.5))
        XCTAssertNil(policy.evaluate(sample(mac: true), at: 2))
        XCTAssertEqual(policy.evaluate(sample(mac: true), at: 3.1), .mac)
    }
    func testPhoneCallOverridesCooldownAndMacMicrophone() {
        var policy = SwitchPolicy()
        policy.completed(.mac, at: 2)
        XCTAssertEqual(policy.evaluate(sample(mac: true, input: true, call: true), at: 2.1), .phone)
    }
    func testPhoneCallPreventsMacTakeover() {
        var policy = SwitchPolicy()
        _ = policy.evaluate(sample(call: true), at: 0)
        XCTAssertNil(policy.evaluate(sample(mac: true, call: true), at: 2))
        XCTAssertNil(policy.evaluate(sample(mac: true, call: true), at: 30))
        XCTAssertNil(policy.evaluate(sample(mac: true), at: 35))
    }
    func testPhoneMediaEdgeWaitsForCooldownThenReturnsOnlyOnce() {
        var policy = SwitchPolicy()
        _ = policy.evaluate(sample(mac: true), at: 0)
        policy.completed(.mac, at: 2)
        XCTAssertNil(policy.evaluate(sample(mac: true, media: true), at: 3))
        XCTAssertEqual(policy.evaluate(sample(mac: true, media: true), at: 8), .phone)
        policy.completed(.phone, at: 8)
        XCTAssertNil(policy.evaluate(sample(mac: true, media: true), at: 20))
    }
    func testMacInputHoldsAgainstPhoneMediaButNotCalls() {
        var policy = SwitchPolicy()
        _ = policy.evaluate(sample(mac: true), at: 0)
        policy.completed(.mac, at: 0)
        XCTAssertNil(policy.evaluate(sample(mac: true, input: true, media: true), at: 10))
        XCTAssertEqual(policy.evaluate(sample(mac: true, input: true, media: true, call: true), at: 11), .phone)
    }
    func testUnknownStateRebaselinesWithoutManufacturingAnEdge() {
        var policy = SwitchPolicy()
        _ = policy.evaluate(sample(), at: 0)
        _ = policy.evaluate(sample(mac: true), at: 1)
        XCTAssertNil(policy.evaluate(sample(valid: false), at: 2))
        XCTAssertNil(policy.evaluate(sample(mac: true), at: 30))
        XCTAssertNil(policy.evaluate(sample(mac: true), at: 32))
    }
    func testReturnOnMacIdleAfterDelay() {
        var policy = SwitchPolicy()
        _ = policy.evaluate(sample(mac: true), at: 0)
        policy.completed(.mac, at: 1)
        XCTAssertNil(policy.evaluate(sample(), at: 3))
        XCTAssertNil(policy.evaluate(sample(), at: 10))
        XCTAssertEqual(policy.evaluate(sample(), at: 13), .phone)
    }
    func testBaselineDoesNotGenerateReturnForExistingPhoneMedia() {
        var policy = SwitchPolicy()
        policy.completed(.mac, at: 0)
        XCTAssertNil(policy.evaluate(sample(mac: true, media: true), at: 10))
        XCTAssertNil(policy.evaluate(sample(mac: true, media: true), at: 11))
    }
    func testRepeatedResumesWorkEvenWhenMacAudioIOStaysOpen() {
        var policy = SwitchPolicy()
        _ = policy.evaluate(sample(), at: 0)
        for cycle in 0..<3 {
            let t = Double(cycle * 20)
            let revision = UInt64(cycle + 1)
            var mac = sample(mac: true); mac.macRevision = revision
            XCTAssertNil(policy.evaluate(mac, at: t + 1))
            XCTAssertEqual(policy.evaluate(mac, at: t + 3), .mac)
            policy.completed(.mac, at: t + 3)
            var phone = sample(mac: true, media: true); phone.macRevision = revision
            _ = policy.evaluate(phone, at: t + 4)
            XCTAssertEqual(policy.evaluate(phone, at: t + 9), .phone)
            policy.completed(.phone, at: t + 9)
            // Mac IO remains active throughout; a new play revision must still work.
            XCTAssertNil(policy.evaluate(phone, at: t + 10))
        }
    }
    func testPhonePauseReturnsToAStillOpenMacPlayer() {
        var policy = SwitchPolicy()
        _ = policy.evaluate(sample(mac: true, media: true), at: 0)
        policy.completed(.phone, at: 1)
        XCTAssertNil(policy.evaluate(sample(mac: true), at: 10))
        XCTAssertEqual(policy.evaluate(sample(mac: true), at: 11.1), .mac)
    }
    func testNewPhonePlayAfterConfirmedPauseDoesNotNeedAnIdlePoll() {
        var policy = SwitchPolicy()
        _ = policy.evaluate(sample(media: true), at: 0)
        _ = policy.evaluate(sample(mac: true, media: true), at: 1)
        XCTAssertEqual(policy.evaluate(sample(mac: true, media: true), at: 2.1), .mac)
        policy.completed(.mac, at: 2.1)
        // The transfer paused Galaxy. A new play can arrive before the next poll.
        XCTAssertNil(policy.evaluate(sample(mac: true, media: true), at: 2.2))
        XCTAssertEqual(policy.evaluate(sample(mac: true, media: true), at: 7.2), .phone)
    }
    func testPhoneConnectionCorrectsStaleMacOwnershipWithoutStealingBack() {
        var policy = SwitchPolicy()
        _ = policy.evaluate(sample(mac: true), at: 0)
        policy.completed(.mac, at: 0)
        policy.phoneConnected(at: 1)
        XCTAssertFalse(policy.ownsMac)
        XCTAssertNil(policy.evaluate(sample(mac: true, media: true), at: 10))
        var resumed = sample(mac: true, media: true); resumed.macRevision = 2
        XCTAssertNil(policy.evaluate(resumed, at: 11))
        XCTAssertEqual(policy.evaluate(resumed, at: 12.1), .mac)
    }

}
