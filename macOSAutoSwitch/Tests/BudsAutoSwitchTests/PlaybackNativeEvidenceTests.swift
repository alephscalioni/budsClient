import XCTest
@testable import BudsAutoSwitch
final class PlaybackNativeEvidenceTests: XCTestCase {
    func testFreshPausedClientWithoutRateIsKnown() {
        let reading = PlaybackNativeEvidence.reading(playing: false, rate: nil, hasInfo: true,
            client: "test.player", observedAt: 10, timedOut: false)
        XCTAssertEqual(reading.playing, false)
        XCTAssertEqual(reading.client, "test.player")
        XCTAssertEqual(reading.observedAt, 10)
        XCTAssertNotNil(reading.observation)
    }
    func testOmittedRateCannotCreatePlayingOrProveAbsentPlayerPaused() {
        for (playing, info, client): (Bool?, Bool, String?) in [(true,true,"player"),(false,false,"player"),(false,true,nil),(nil,true,"player"),(false,true,"")] {
            XCTAssertNil(PlaybackNativeEvidence.reading(playing: playing, rate: nil, hasInfo: info,
                client: client, observedAt: 10, timedOut: false).observation)
        }
    }
    func testContradictionsAndIncompleteCallbacksRemainUnknown() {
        for (playing, rate): (Bool,Double) in [(false,1),(true,0),(false,-1),(true,.nan),(false,.infinity)] {
            XCTAssertNil(PlaybackNativeEvidence.reading(playing: playing, rate: rate, hasInfo: true,
                client: "player", observedAt: 10, timedOut: false).observation)
        }
        XCTAssertNil(PlaybackNativeEvidence.reading(playing: false, rate: nil, hasInfo: true,
            client: "player", observedAt: 10, timedOut: true).observation)
    }
    func testConsistentExplicitRateStillProvesPlayback() {
        XCTAssertEqual(PlaybackNativeEvidence.reading(playing: true, rate: 1, hasInfo: true,
            client: "player", observedAt: 10, timedOut: false).playing, true)
    }
}
