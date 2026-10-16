import XCTest
@testable import BudsAutoSwitch

final class NativeSamsungBudsContextEvidenceTests: XCTestCase {
    private let address = try! SamsungPeerAddress(bytes: Data([2, 0x13, 0x24, 0x35, 0x46, 0x57]))
    private func frame(_ payload: [UInt8]) -> SamsungMdePacket.Frame {
        .init(command: 0x45, payload: Data(payload), sequence: 0, isResponse: false, isFragment: false)
    }
    private let complete: [UInt8] = [6, 2, 1, 2, 7, 2, 1, 2, 31, 2, 1, 1]
    private func profile(_ store: NativeSamsungBudsContextEvidence, at now: Double = 10) -> NativeSamsungBudsProfileObservation {
        .init(address: address, session: store.session!, observedAt: now, hfp: .connected, bis: false)
    }
    func testOnlyExplicitCompleteFreshSameSessionInputsProduceContext() throws {
        var s = NativeSamsungBudsContextEvidence(); s.begin(address: address, at: 10)
        s.observe(frame(complete), session: s.session!, at: 10)
        XCTAssertNil(s.context(profiles: nil, foregroundA2DP: true, at: 10))
        XCTAssertNil(s.context(profiles: profile(s), foregroundA2DP: false, at: 10))
        let context = try XCTUnwrap(s.context(profiles: profile(s), foregroundA2DP: true, at: 10))
        XCTAssertEqual(context.encode(), Data([0x33, 0x11, 0x57, 0x4D]))
        XCTAssertEqual(s.metadataReadiness(at: 10), ["session_available": true, "wearing_known": true, "spp_capacity_known": true])
        XCTAssertNil(s.context(profiles: profile(s, at: 15.1), foregroundA2DP: true, at: 15.1), "fresh profiles cannot refresh expired sensors")
        s.observe(frame(complete), session: s.session!, at: 16)
        XCTAssertNil(s.context(profiles: profile(s), foregroundA2DP: true, at: 16), "fresh sensors cannot refresh old profiles")
    }
    func testUnknownReplacesEvidenceButUnreportedDoesNotRefreshIt() throws {
        var s = NativeSamsungBudsContextEvidence(); s.begin(address: address, at: 10)
        s.observe(frame(complete), session: s.session!, at: 10)
        s.observe(frame([31, 2, 1, 2]), session: s.session!, at: 14)
        XCTAssertEqual(s.context(profiles: profile(s, at: 14), foregroundA2DP: true, at: 14)?.encode(), Data([0x33, 0x11, 0x57, 0x0D]))
        XCTAssertNil(s.context(profiles: profile(s, at: 15.1), foregroundA2DP: true, at: 15.1))
        s.observe(frame(complete + [6, 2, 1, 0]), session: s.session!, at: 16)
        XCTAssertNil(s.context(profiles: profile(s, at: 16), foregroundA2DP: true, at: 16))
        s.observe(frame([6, 2, 1, 1]), session: s.session!, at: 17)
        XCTAssertEqual(s.context(profiles: profile(s, at: 17), foregroundA2DP: true, at: 17)?.wearing, true)
        s.observe(frame([31, 2, 1, 255]), session: s.session!, at: 18)
        XCTAssertNil(s.context(profiles: profile(s, at: 18), foregroundA2DP: true, at: 18))
    }
    func testMalformedRelevantFrameInvalidatesAndRetiredSessionCannotRepopulate() throws {
        var s = NativeSamsungBudsContextEvidence(); s.begin(address: address, at: 10)
        let old = try XCTUnwrap(s.session)
        s.observe(frame(complete), session: old, at: 10)
        s.observe(frame([6, 2, 1, 1, 31]), session: old, at: 11)
        XCTAssertEqual(s.metadataReadiness(at: 11)["wearing_known"], false)
        s.begin(address: address, at: 12)
        s.observe(frame(complete), session: old, at: 13)
        XCTAssertNil(s.context(profiles: profile(s, at: 13), foregroundA2DP: true, at: 13))
        s.observe(frame(complete), session: s.session!, at: 13)
        let wrong = NativeSamsungBudsProfileObservation(address: address, session: old, observedAt: 13, hfp: .connected, bis: false)
        XCTAssertNil(s.context(profiles: wrong, foregroundA2DP: true, at: 13))
        s.reset(); XCTAssertNil(s.session)
        s.observe(frame(complete), session: old, at: 14)
        XCTAssertFalse(s.metadataReadiness(at: 14)["session_available"]!)
    }
    func testClockAndAddressDoNotAllowStaleEvidenceToBecomeCurrent() throws {
        var s = NativeSamsungBudsContextEvidence(); s.begin(address: address, at: 10)
        s.observe(frame(complete), session: s.session!, at: 11)
        s.observe(frame([6, 2, 1, 0]), session: s.session!, at: 10.5)
        XCTAssertNotNil(s.context(profiles: profile(s, at: 11), foregroundA2DP: true, at: 11))
        for time in [Double.nan, .infinity, 9.0] {
            XCTAssertNil(s.context(profiles: profile(s, at: 11), foregroundA2DP: true, at: time))
        }
        let wrong = NativeSamsungBudsProfileObservation(address: try SamsungPeerAddress(bytes: Data([0, 1, 2, 3, 4, 5])),
            session: s.session!, observedAt: 11, hfp: .connected, bis: false)
        XCTAssertNil(s.context(profiles: wrong, foregroundA2DP: true, at: 11))
        s.begin(address: address, at: .nan); XCTAssertNil(s.session)
    }
    func testUncorrelatedReadCannotOverwriteRefreshOrResurrectNotification() throws {
        var s = NativeSamsungBudsContextEvidence(); s.begin(address: address, at: 10)
        func read(_ payload: [UInt8]) -> SamsungMdePacket.Frame {
            .init(command: 0x44, payload: Data([0, 2] + payload), sequence: 0, isResponse: true, isFragment: false)
        }
        s.observe(read(complete), session: s.session!, at: 10)
        XCTAssertNotNil(s.context(profiles: profile(s), foregroundA2DP: true, at: 10), "initial read can seed facts")
        s.observe(frame([6, 2, 1, 1]), session: s.session!, at: 11)
        s.observe(read([6, 2, 1, 2]), session: s.session!, at: 12)
        XCTAssertEqual(s.context(profiles: profile(s, at: 12), foregroundA2DP: true, at: 12)?.wearing, true)
        s.observe(frame([6, 2, 1, 0]), session: s.session!, at: 13)
        s.observe(read(complete), session: s.session!, at: 14)
        XCTAssertNil(s.context(profiles: profile(s, at: 14), foregroundA2DP: true, at: 14))
        s.observe(frame(complete), session: s.session!, at: 15)
        s.observe(read(complete), session: s.session!, at: 20.1)
        XCTAssertNil(s.context(profiles: profile(s, at: 20.1), foregroundA2DP: true, at: 20.1), "READ cannot refresh expired NOTIFY")
    }
}
