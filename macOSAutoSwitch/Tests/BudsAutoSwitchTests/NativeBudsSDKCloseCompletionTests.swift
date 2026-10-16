import XCTest
@testable import BudsAutoSwitch

final class NativeBudsSDKCloseCompletionTests: XCTestCase {
    func testSuccessReturnCannotReleaseResourcesBeforeTheExactCloseReceipt() {
        var clock: TimeInterval = 0, received = false, cleared = false
        let result = NativeBudsSDKCloseCompletion.finish(status: 0, wasOpen: true,
            observed: { received }, isOpen: { !received }, clearDelegate: {
                XCTAssertTrue(received); cleared = true
            }, sleep: { interval in
                XCTAssertFalse(cleared)
                clock += interval
                if clock >= 0.15 { received = true }
            }, now: { clock })
        XCTAssertEqual(result, 0); XCTAssertTrue(cleared)
        XCTAssertEqual(clock, 0.15, accuracy: 0.0001)
    }

    func testMissingReceiptOrStillOpenAtDeadlineKeepsDelegateAndUnresolvedClose() {
        for received in [false, true] {
            var clock: TimeInterval = 0, cleared = false
            let result = NativeBudsSDKCloseCompletion.finish(status: 0, wasOpen: true,
                observed: { received }, isOpen: { received }, clearDelegate: { cleared = true },
                sleep: { clock += $0 }, now: { clock })
            XCTAssertNotEqual(result, 0); XCTAssertFalse(cleared)
            XCTAssertLessThanOrEqual(clock, 1.5)
        }
    }

    func testLegacyChannelWithoutCloseObserverRetainsItsExistingPolicy() {
        var cleared = false
        XCTAssertEqual(NativeBudsSDKCloseCompletion.finish(status: 0, wasOpen: true,
            observed: nil, isOpen: { true }, clearDelegate: { cleared = true },
            sleep: { _ in XCTFail("Legacy SMEP policy must not acquire a new wait") }), 0)
        XCTAssertTrue(cleared)
    }

    @MainActor func testCancelledMailboxStillReceivesClosureWithoutDeliveringOldDataOrClosingAnotherChannel() {
        final class Channel {}
        let selected = Channel(), foreign = Channel()
        let callbacks = NativeBudsSettingsOpenCallbacks<Channel>(close: { _ in XCTFail("No new close") })
        callbacks.cancel()
        callbacks.receive(.closed(foreign))
        XCTAssertFalse(callbacks.observedClose(of: selected))
        XCTAssertTrue(callbacks.observedClose(of: foreign))
        callbacks.receive(.closed(selected))
        XCTAssertTrue(callbacks.observedClose(of: selected))
        XCTAssertTrue(callbacks.isCancelled)
    }
    @MainActor func testCloseReceiptBeforeOrAfterLateWaiterStillCompletesCancelledLease() async {
        final class Channel {}
        let channel = Channel()
        let callbacks = NativeBudsSettingsOpenCallbacks<Channel>(close: { _ in XCTFail() })
        callbacks.cancel()
        let first = expectation(description: "Late close settled")
        callbacks.whenClosed(channel) { first.fulfill() }
        callbacks.receive(.closed(channel))
        await fulfillment(of: [first], timeout: 1)
        let second = expectation(description: "Already observed close settled")
        callbacks.whenClosed(channel) { second.fulfill() }
        await fulfillment(of: [second], timeout: 1)
    }
}
