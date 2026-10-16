import XCTest
@testable import BudsAutoSwitch

final class NativeBudsOpeningRunLoopTests: XCTestCase {
    private final class Channel {}
    private final class Callback: NSObject {
        let arrived: XCTestExpectation
        init(_ arrived: XCTestExpectation) { self.arrived = arrived }
        @objc func sdkCallback() {
            XCTAssertFalse(Thread.isMainThread)
            arrived.fulfill()
        }
    }

    @MainActor func testSDKCallbackOnOpeningThreadStillRunsAfterSynchronousOpenReturned() async {
        let callbackArrived = expectation(description: "SDK callback after open returned")
        let opened = expectation(description: "Bounded open returned to main actor")
        let callback = Callback(callbackArrived)
        NativeBudsSettingsOpenWorker.run(open: {
            XCTAssertFalse(Thread.isMainThread)
            let thread = Thread.current
            // Simulate a vendor callback queued only AFTER the synchronous SDK
            // call returns. It must still have a running destination run loop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                callback.perform(#selector(Callback.sdkCallback), on: thread, with: nil, waitUntilDone: false)
            }
            return (0, Channel())
        }, isOpen: { _ in true }, completion: { status, channel in
            XCTAssertTrue(Thread.isMainThread); XCTAssertEqual(status, 0); XCTAssertNotNil(channel)
            opened.fulfill()
        })
        await fulfillment(of: [opened, callbackArrived], timeout: 2)
    }
}
