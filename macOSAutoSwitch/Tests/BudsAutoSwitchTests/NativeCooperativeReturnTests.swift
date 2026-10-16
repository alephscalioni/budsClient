import XCTest
@testable import BudsAutoSwitch

@MainActor final class NativeCooperativeReturnTests: XCTestCase {
    func testCallStartingDuringReadyPauseCannotMoveMacToMutedWaitingOutput() async throws {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start()
        var acquired: (UUID, String)?
        model.onMacAcquired = { acquired = ($0, $1) }
        await h.acquire(model)
        let (epoch, address) = try XCTUnwrap(acquired)
        let writes = h.routeWrites, banners = h.hud.count
        h.holdPause = true
        model.requestYieldForAuthenticatedReady(epoch: epoch, budsAddress: address)
        await h.settle(); XCTAssertNotNil(h.pauseGate)
        h.inputActive = true
        h.holdPause = false; h.pauseGate?.resume(); h.pauseGate = nil
        await h.settle()
        XCTAssertEqual(h.routeWrites, writes); XCTAssertEqual(h.output, 2)
        XCTAssertEqual(h.physicalCloses, 0); XCTAssertEqual(h.hud.count, banners)
        XCTAssertEqual(model.route, "Mac"); XCTAssertTrue(model.enabled); XCTAssertNil(model.error)
        h.inputActive = false
        await h.stop(model)
    }

    func testAccountReadyRejectsWrongAcquisitionAndDeviceAndWorksWithoutLaboratoryFlags() async throws {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start()
        var acquired: (UUID, String)?
        model.onMacAcquired = { acquired = ($0, $1) }
        await h.acquire(model)
        let (epoch, address) = try XCTUnwrap(acquired), baseline = h.pauses
        model.requestYieldForAuthenticatedReady(epoch: UUID(), budsAddress: address)
        model.requestYieldForAuthenticatedReady(epoch: epoch, budsAddress: "22:34:56:78:9A:BC")
        await h.settle(); XCTAssertEqual(h.pauses, baseline)
        model.requestYieldForAuthenticatedReady(epoch: epoch, budsAddress: address)
        await h.settle(); XCTAssertEqual(h.pauses, baseline + 1)
        XCTAssertEqual(h.output, 1); XCTAssertTrue(h.armed)
        XCTAssertEqual(h.physicalCloses, 0); XCTAssertNotEqual(model.route, "Galaxy")
        h.notify(.background); await h.settle()
        XCTAssertEqual(model.route, "Galaxy")
        await h.stop(model)
    }

    #if DEBUG
    func testEarlyPhoneIntentLabRequiresExplicitFlagsAndCannotClaimPhoneBeforeBackground() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start()
        await h.acquire(model)
        let baseline = h.pauses
        model.laboratoryYieldForObservedPhoneIntent(); await h.settle()
        XCTAssertEqual(h.pauses, baseline)
        model.laboratoryCooperativeForegroundRejection = true
        model.laboratoryProvisionalRouteRelease = true
        model.laboratoryYieldForObservedPhoneIntent(); await h.settle()
        XCTAssertEqual(h.pauses, baseline + 1)
        XCTAssertEqual(h.output, 1); XCTAssertTrue(h.armed)
        XCTAssertEqual(h.physicalCloses, 0)
        XCTAssertNotEqual(model.route, "Galaxy")
        model.laboratoryYieldForObservedPhoneIntent(); await h.settle()
        XCTAssertEqual(h.pauses, baseline + 1)
        h.notify(.background); await h.settle()
        XCTAssertEqual(model.route, "Galaxy")
        XCTAssertEqual(h.physicalCloses, 1)
        await h.stop(model)
    }

    func testEarlyPhoneIntentLabCannotPauseUnknownMediaOrInput() async {
        for unknown in [false, true] {
            let h = NativeControllerHarness(); h.physicalReleasePolicy = true
            let model = await h.start()
            model.laboratoryCooperativeForegroundRejection = true
            model.laboratoryProvisionalRouteRelease = true
            await h.acquire(model)
            let baseline = h.pauses
            h.sampleIsUnknown = unknown; h.inputActive = !unknown
            model.laboratoryYieldForObservedPhoneIntent(); await h.settle()
            XCTAssertEqual(h.pauses, baseline)
            XCTAssertEqual(h.output, 2)
            XCTAssertEqual(h.physicalCloses, 0)
            h.sampleIsUnknown = false; h.inputActive = false
            await h.stop(model)
        }
    }
    #endif

    func testProvisionalWaitingRouteNeverClaimsPhoneOrDisconnectsBeforeBackground() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start()
        model.laboratoryCooperativeForegroundRejection = true
        model.laboratoryProvisionalRouteRelease = true
        await h.acquire(model)
        let banners = h.hud.count
        h.notify(reason: 132); await h.settle()
        XCTAssertFalse(h.playing)
        XCTAssertTrue(h.armed); XCTAssertEqual(h.output, 1)
        XCTAssertEqual(model.route, "Sem saída confirmada")
        XCTAssertEqual(h.physicalCloses, 0)
        XCTAssertEqual(h.hud.count, banners)
        XCTAssertTrue(model.enabled); XCTAssertNil(model.error)
        h.notify(.background); await h.settle()
        XCTAssertEqual(model.route, "Galaxy")
        XCTAssertEqual(h.physicalCloses, 1)
        await h.stop(model)
    }
    func testExplicitMacPlayAfterProvisionalWaitingRouteRequiresFreshRadioConfirmation() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start()
        model.laboratoryCooperativeForegroundRejection = true
        model.laboratoryProvisionalRouteRelease = true
        await h.acquire(model)
        h.notify(reason: 132); await h.settle()
        let requests = h.requests
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.requests, requests + 1)
        XCTAssertEqual(h.output, 1)
        XCTAssertNotEqual(model.route, "Mac")
        h.notify(reason: 132); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        XCTAssertTrue(h.playing)
        await h.stop(model)
    }
    func testPlaybackReportsFollowVerifiedLocalStateAndNeverAcquireOwnership() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start()
        model.laboratoryCooperativeForegroundRejection = true
        model.laboratoryPlaybackReports = true
        XCTAssertFalse(h.commands.contains(SamsungMdePacket.playbackStatus(.playing)))
        await h.acquire(model); await h.advance(0.2)
        XCTAssertEqual(h.commands.filter { $0 == SamsungMdePacket.playbackStatus(.playing) }.count, 1)
        let requests = h.requests
        h.notify(reason: 132); await h.settle()
        XCTAssertFalse(h.playing)
        XCTAssertEqual(h.commands.filter { $0 == SamsungMdePacket.playbackStatus(.paused) }.count, 1)
        XCTAssertEqual(h.requests, requests)
        XCTAssertEqual(model.route, "Mac", "Playback reports do not fabricate remote ownership")
        h.notify(reason: 132); await h.advance(0.2)
        XCTAssertEqual(h.commands.filter { $0 == SamsungMdePacket.playbackStatus(.paused) }.count, 1)
        await h.stop(model)
    }
    func testFailedPauseNeverQueuesPausedPlaybackReport() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start()
        model.laboratoryCooperativeForegroundRejection = true
        model.laboratoryPlaybackReports = true
        await h.acquire(model)
        h.pauseError = "unverified player"
        h.notify(reason: 132); await h.settle()
        XCTAssertFalse(h.commands.contains(SamsungMdePacket.playbackStatus(.paused)))
        h.pauseError = nil
        await h.stop(model)
    }
    func testOneVerifiedPauseDoesNotClaimRemoteOwnershipUntilRealBackground() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start(); model.laboratoryCooperativeForegroundRejection = true
        await h.acquire(model)
        let pauseBaseline = h.pauses, bannerBaseline = h.hud.count
        h.notify(reason: 132); await h.settle()
        XCTAssertEqual(h.pauses, pauseBaseline + 1)
        XCTAssertFalse(h.playing)
        XCTAssertEqual(model.route, "Mac")
        XCTAssertEqual(h.output, 2)
        XCTAssertEqual(h.physicalCloses, 0)
        XCTAssertEqual(h.hud.count, bannerBaseline)
        XCTAssertTrue(model.enabled); XCTAssertNil(model.error)
        h.notify(reason: 132); await h.settle()
        XCTAssertEqual(h.pauses, pauseBaseline + 1, "Duplicate ingress must never pause twice")
        h.notify(.background); await h.settle()
        XCTAssertEqual(model.route, "Galaxy")
        XCTAssertEqual(h.output, 1)
        XCTAssertEqual(h.physicalCloses, 1)
        XCTAssertTrue(h.armed)
        await h.stop(model)
    }

    func testRequestForeground132StillConfirmsAcquisitionWithoutProvisionalPause() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start(); model.laboratoryCooperativeForegroundRejection = true
        h.play(); await h.advance(0.2)
        let pauses = h.pauses
        h.notify(reason: 132); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        XCTAssertEqual(h.pauses, pauses)
        XCTAssertTrue(h.playing)
        await h.stop(model)
    }

    func testUnknownPlaybackOrActiveInputCannotAuthorizeProvisionalPause() async {
        for unknown in [false, true] {
            let h = NativeControllerHarness(); h.physicalReleasePolicy = true
            let model = await h.start(); model.laboratoryCooperativeForegroundRejection = true
            await h.acquire(model)
            let pauses = h.pauses
            h.sampleIsUnknown = unknown; h.inputActive = !unknown
            h.notify(reason: 132); await h.settle()
            XCTAssertEqual(h.pauses, pauses)
            XCTAssertTrue(h.playing); XCTAssertTrue(model.enabled)
            h.sampleIsUnknown = false; h.inputActive = false
            await h.stop(model)
        }
    }

    func testUnconfirmedProvisionalPauseDoesNotDisableSwitchingOrReleaseRoute() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start(); model.laboratoryCooperativeForegroundRejection = true
        await h.acquire(model)
        h.pauseError = "unverified player"
        h.notify(reason: 132); await h.settle()
        XCTAssertTrue(model.enabled); XCTAssertNil(model.error)
        XCTAssertEqual(model.route, "Mac"); XCTAssertEqual(h.output, 2)
        XCTAssertEqual(h.physicalCloses, 0)
        XCTAssertTrue(model.canManageSettings)
        h.pauseError = nil
        await h.stop(model)
    }

    func testLaterExplicitPlayInSameOwnershipIsNotPausedByDuplicateRejection() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start(); model.laboratoryCooperativeForegroundRejection = true
        await h.acquire(model)
        h.notify(reason: 132); await h.settle()
        let pauses = h.pauses
        h.play(); await h.advance(0.2)
        h.notify(reason: 132); await h.settle()
        XCTAssertEqual(h.pauses, pauses)
        XCTAssertTrue(h.playing); XCTAssertEqual(model.route, "Mac")
        XCTAssertTrue(model.canManageSettings)
        await h.stop(model)
    }
}
