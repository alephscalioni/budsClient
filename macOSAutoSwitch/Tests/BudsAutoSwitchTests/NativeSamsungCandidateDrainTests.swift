import XCTest
@testable import BudsAutoSwitch

final class NativeSamsungCandidateDrainTests: XCTestCase {
    func testPreferredRouteWaitsForPreviousSDKLeaseWithoutConsumingCandidate() {
        var selection = NativeSamsungPeerCandidateSelection()
        let peripheral = UUID(), token = UUID(); selection.begin(now: 10)
        XCTAssertNil(selection.offer(token: token, identifier: peripheral, now: 10,
            preferred: peripheral, isTemporarilyUnavailable: { _ in true }, isExcluded: { _ in false }))
        XCTAssertNil(selection.poll(now: 11.5, preferred: peripheral,
            isTemporarilyUnavailable: { _ in true }, isExcluded: { _ in false }))
        XCTAssertEqual(selection.poll(now: 11.6, preferred: peripheral,
            isTemporarilyUnavailable: { _ in false }, isExcluded: { _ in false }), token)
        XCTAssertNil(selection.poll(now: 12, preferred: peripheral, isExcluded: { _ in false }))
    }

    func testUnhintedDrainingRouteIsRetainedButRejectedIdentityIsRemoved() {
        for excluded in [true, false] {
            var selection = NativeSamsungPeerCandidateSelection()
            let peripheral = UUID(), token = UUID(); selection.begin(now: 1)
            XCTAssertNil(selection.offer(token: token, identifier: peripheral, now: 1,
                preferred: nil, isTemporarilyUnavailable: { _ in true }, isExcluded: { _ in excluded }))
            XCTAssertEqual(selection.poll(now: 3, preferred: nil, isExcluded: { _ in false }), excluded ? nil : token)
        }
    }
}
