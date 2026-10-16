import XCTest
@testable import BudsAutoSwitch

final class MacPlaybackLocalityTests: XCTestCase {
    func testWebKitMustBelongToSafariBeforeAuthorizingSafariAudio() {
        let foreign = MacPlaybackProcessActivity.ProcessSample(bundle: "com.apple.WebKit.GPU",
            responsibleBundle: "example.otherApp", output: true, eligible: true)
        let own = MacPlaybackProcessActivity.ProcessSample(bundle: "com.apple.WebKit.GPU",
            responsibleBundle: "com.apple.Safari", output: true, eligible: true)
        let wrong = MacPlaybackProcessActivity.classify(client: "com.apple.Safari", samples: [foreign])
        XCTAssertEqual(wrong.clientOutput, false); XCTAssertTrue(wrong.anyAppOutput)
        let correct = MacPlaybackProcessActivity.classify(client: "com.apple.Safari", samples: [own])
        XCTAssertEqual(correct.clientOutput, true)
        let unresolved = MacPlaybackProcessActivity.ProcessSample(bundle: "com.apple.WebKit.GPU",
            responsibleBundle: nil, output: true, eligible: true)
        XCTAssertEqual(MacPlaybackProcessActivity.classify(client: "com.apple.Safari", samples: [unresolved]).clientOutput, false)
    }
    func testProcessReadFailureCannotEstablishSilence() {
        let unknown = MacPlaybackProcessActivity.ProcessSample(bundle: "com.spotify.client",
            responsibleBundle: nil, output: nil, eligible: true)
        XCTAssertNil(MacPlaybackProcessActivity.classify(client: "com.spotify.client", samples: [unknown]).clientOutput)
    }
    private func playing(revision: UInt64 = 1) -> MacPlaybackIntent {
        .init(isPlaying: true, clientID: "com.spotify.client", revision: revision, observedAt: 10)
    }
    func testSpotifyConnectEchoWithoutLocalOutputCannotReacquireMac() {
        var evidence = NativeSwitchEvidence()
        _ = evidence.playEdge(playing: false, revision: 0)
        for revision in 1...8 {
            let local = MacPlaybackLocality.apply(playing(revision: UInt64(revision)), clientOutput: false, anyAppOutput: false)
            XCTAssertEqual(local.isPlaying, false)
            XCTAssertEqual(local.reportedIsPlaying, true)
            XCTAssertFalse(evidence.playEdge(playing: local.isPlaying == true, revision: local.revision))
        }
        let actual = MacPlaybackLocality.apply(playing(revision: 9), clientOutput: true, anyAppOutput: true)
        XCTAssertTrue(evidence.playEdge(playing: actual.isPlaying == true, revision: actual.revision))
    }
    func testAnotherAppOrUnknownOutputIsNotLocalIntentOrConfirmedPause() {
        for (client, any): (Bool?, Bool) in [(false, true), (nil, false), (nil, true)] {
            XCTAssertNil(MacPlaybackLocality.apply(playing(), clientOutput: client, anyAppOutput: any).isPlaying)
        }
    }
    func testLocalOutputCannotInventPlayWhenMediaRemoteIsPausedOrUnknown() {
        for state: Bool? in [false, nil] {
            let raw = MacPlaybackIntent(isPlaying: state, clientID: "player", revision: 3, observedAt: 10)
            let result = MacPlaybackLocality.apply(raw, clientOutput: true, anyAppOutput: true)
            XCTAssertEqual(result.isPlaying, state)
            XCTAssertEqual(result.revision, 3)
            XCTAssertEqual(result.observedAt, 10)
        }
    }
}
