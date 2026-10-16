import XCTest
@testable import BudsAutoSwitch

@MainActor final class NativeAcquisitionOutputGapTests: XCTestCase {
    func testColdOpenGapWaitsForPositiveLocalOutputWithoutLosingAcceptedPlay() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
        h.openHook = { h.localOutputUnavailable = true }
        let model = await h.start()
        h.play(); await h.advance(0.2)
        XCTAssertTrue(model.busy); XCTAssertEqual(h.requests, 0)
        await h.advance(0.2)
        XCTAssertTrue(model.busy); XCTAssertEqual(h.requests, 0)
        h.localOutputUnavailable = false; await h.advance(0.06)
        XCTAssertEqual(h.requests, 1)
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac"); XCTAssertTrue(h.playing)
        await h.stop(model)
    }

    func testRouteGapCannotClaimMacUntilOutputActuallyResumes() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        h.routeHook = { h.localOutputUnavailable = true }
        let model = await h.start()
        h.play(); await h.advance(0.2)
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(h.output, 2); XCTAssertNotEqual(model.route, "Mac")
        XCTAssertTrue(model.busy)
        h.localOutputUnavailable = false; await h.advance(0.06)
        XCTAssertEqual(model.route, "Mac"); XCTAssertEqual(h.requests, 1)
        h.routeHook = nil
        await h.stop(model)
    }

    func testRealPlayerPauseDuringOutputGapStillCancelsAcquisition() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
        h.openHook = { h.localOutputUnavailable = true }
        let model = await h.start()
        h.play(); await h.advance(0.2)
        XCTAssertTrue(model.busy)
        h.playing = false; await h.advance(0.06)
        XCTAssertFalse(model.busy); XCTAssertEqual(h.requests, 0)
        XCTAssertNotEqual(model.route, "Mac"); XCTAssertEqual(h.output, 1)
        h.localOutputUnavailable = false
        await h.stop(model)
    }

    func testRemoteOnlyPlayerReportCannotCreateAcquisitionWithoutLocalOutput() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
        h.localOutputUnavailable = true
        let model = await h.start()
        h.play(); await h.advance(0.2); await h.advance(2)
        XCTAssertEqual(h.opens, 0); XCTAssertEqual(h.requests, 0)
        XCTAssertNotEqual(model.route, "Mac")
        h.playing = false; h.localOutputUnavailable = false
        await h.stop(model)
    }

    func testOutputGapCannotExtendWholeAcquisitionDeadline() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
        h.openHook = { h.localOutputUnavailable = true }
        let model = await h.start()
        h.play(); await h.advance(0.2)
        XCTAssertTrue(model.busy)
        await h.advance(12.1)
        XCTAssertGreaterThan(h.restores, 0, "The original budget must restore the protected output before recovery")
        XCTAssertEqual(h.requests, 0); XCTAssertFalse(h.armed)
        h.localOutputUnavailable = false
        await h.stop(model)
    }
}
