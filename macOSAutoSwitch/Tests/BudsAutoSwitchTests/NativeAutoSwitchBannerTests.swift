import XCTest
@testable import BudsAutoSwitch

@MainActor private final class NativeBannerRecorder {
    var events: [NativeConnectionBannerEvent] = []
}

final class NativeAutoSwitchBannerTests: XCTestCase {
    @MainActor private func start(_ harness: NativeControllerHarness) async
        -> (NativeAutoSwitchModel, NativeBannerRecorder) {
        let recorder = NativeBannerRecorder()
        var environment = harness.environment()
        environment.banner = { event, _ in recorder.events.append(event) }
        let model = NativeAutoSwitchModel(environment: environment)
        await model.refresh()
        XCTAssertTrue(recorder.events.isEmpty)
        model.start(transportGranted: true)
        await harness.settle()
        return (model, recorder)
    }

    @MainActor func testStartupSnapshotsAndOrdinaryLocalPlayAreSilent() async {
        let h = NativeControllerHarness()
        let (model, recorder) = await start(h)
        h.notify(.background, stream: .a2dp, command: 0x44) // uncorrelated READ
        h.notify(.background, stream: [])
        await h.settle()
        XCTAssertTrue(recorder.events.isEmpty)
        await h.acquire(model)
        XCTAssertTrue(recorder.events.isEmpty)
        XCTAssertTrue(h.hud.isEmpty, "Typed callback replaces the legacy callback")
        XCTAssertEqual(h.requests, 1)
        await h.stop(model)
    }

    @MainActor func testAdoptingAnAlreadyConnectedMacRouteIsSilentEvenAfterRemoteProof() async {
        for remote in [false, true] {
            let h = NativeControllerHarness(); h.output = 2
            let (model, recorder) = await start(h)
            if remote { h.notify(.background); await h.settle() }
            h.notify(); await h.settle()
            h.play(); await h.advance(0.2)
            XCTAssertEqual(model.route, "Mac"); XCTAssertEqual(h.requests, 0)
            XCTAssertTrue(recorder.events.isEmpty); XCTAssertTrue(h.hud.isEmpty)
            await h.stop(model)
        }
    }

    @MainActor func testActualRemoteOwnershipThenVerifiedAcquisitionEmitsOnce() async {
        let h = NativeControllerHarness()
        let (model, recorder) = await start(h)
        h.notify(.background); await h.settle()
        XCTAssertTrue(recorder.events.isEmpty, "Remote ownership alone is not a completed transfer")
        h.play(); await h.advance(0.2)
        XCTAssertTrue(recorder.events.isEmpty, "Request submission is not acquisition")
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        XCTAssertEqual(recorder.events.map(\.kind), [.acquiredFromOtherDevice])
        XCTAssertEqual(recorder.events.first?.address, model.selectedBuds)
        XCTAssertEqual(recorder.events.first?.occurredAt, h.time)
        for _ in 0..<10 { h.notify() }
        await h.advance(2)
        XCTAssertEqual(recorder.events.count, 1); XCTAssertTrue(h.hud.isEmpty)
        await h.stop(model)
    }

    @MainActor func testEmptyUnknownOrRejectedStreamCannotEstablishRemoteOwnership() async {
        for (flags, reason) in [(SamsungMdePacket.StreamType(), UInt8(0)),
                                (.autoSwitchRequest, 0), (.init(rawValue: 0x40), 0), (.a2dp, 132)] {
            let h = NativeControllerHarness()
            let (model, recorder) = await start(h)
            h.notify(.background, stream: flags, reason: reason); await h.settle()
            await h.acquire(model)
            XCTAssertTrue(recorder.events.isEmpty)
            await h.stop(model)
        }
    }

    @MainActor func testFailedOrCancelledAcquisitionNeverPublishesRemoteProof() async {
        for failure in ["radio", "route", "pause", "stop"] {
            let h = NativeControllerHarness()
            let (model, recorder) = await start(h)
            h.notify(.background); await h.settle()
            h.play(); await h.advance(0.2)
            switch failure {
            case "radio": h.linked = false
            case "route": h.routeHook = { h.output = 3 }
            case "pause": h.linkHook = { h.playing = false }
            default: model.stop()
            }
            h.notify(); await h.advance(0.15)
            XCTAssertTrue(recorder.events.isEmpty); XCTAssertTrue(h.hud.isEmpty)
            await h.stop(model)
        }
    }

    @MainActor func testSelectionChangedSynchronouslyAtOwnershipCallbackSuppressesOldBanner() async {
        let h = NativeControllerHarness()
        let (model, recorder) = await start(h)
        h.notify(.background); await h.settle()
        model.onMacAcquired = { _, _ in model.selectedBuds = "AA:BB:CC:DD:EE:02" }
        await h.acquire(model)
        XCTAssertTrue(recorder.events.isEmpty)
        model.onMacAcquired = nil
        await h.stop(model)
    }

    @MainActor func testRecoveryDiscardsPresentationProofFromPreviousControlSession() async {
        let h = NativeControllerHarness()
        let (model, recorder) = await start(h)
        h.notify(.background); await h.settle()
        let oldFrame = h.frame
        h.loseChannel(); await h.settle(); await h.advance(1)
        // Even a retained remote callback is fenced by the controller session.
        var payload = [UInt8](repeating: 0, count: 18)
        payload[1] = SamsungMdePacket.MultipointStatus.State.background.rawValue
        payload[7] = SamsungMdePacket.StreamType.a2dp.rawValue
        oldFrame?(.init(command: 0x45, payload: Data([0x02, 0x05, 18] + payload),
                        sequence: 0, isResponse: false, isFragment: false))
        await h.acquire(model)
        XCTAssertTrue(recorder.events.isEmpty)
        await h.stop(model)
    }

    @MainActor func testDepartureWaitsForConfirmedYieldAndNeverNamesSelectedPhone() async {
        let h = NativeControllerHarness()
        let (model, recorder) = await start(h)
        model.selectedPhone = "Unverified S25 Ultra"
        await h.acquire(model)
        h.holdRoute = true
        h.notify(.background); await h.settle()
        XCTAssertTrue(recorder.events.isEmpty, "Pause and pending route write are not completed yield")
        h.holdRoute = false; h.routeGate?.resume(); h.routeGate = nil
        await h.settle()
        XCTAssertEqual(recorder.events.map(\.kind), [.departedFromMac(destination: nil)])
        h.notify(.background); await h.advance(0.2)
        XCTAssertEqual(recorder.events.count, 1)
        await h.stop(model)
    }

    @MainActor func testAbortedOrFailedYieldNeverEmitsDeparture() async {
        for scenario in ["pauseFailure", "foreground", "newPlayPhysical"] {
            let h = NativeControllerHarness(); h.physicalReleasePolicy = scenario == "newPlayPhysical"
            let (model, recorder) = await start(h)
            await h.acquire(model)
            if scenario == "pauseFailure" { h.pauseError = "cannot-pause" }
            else {
                h.routeHook = {
                    if h.output == 1 {
                        if scenario == "foreground" { h.notify() }
                        else { h.play() }
                    }
                }
            }
            h.notify(.background); await h.settle()
            XCTAssertTrue(recorder.events.isEmpty)
            h.pauseError = nil; h.routeHook = nil
            await h.stop(model)
        }
    }

    @MainActor func testPhysicalDepartureNeedsFreshLinkAbsenceAndNotJustCloseReturn() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let (model, recorder) = await start(h)
        await h.acquire(model)
        h.closeDropsLink = false
        h.notify(.background); await h.settle()
        XCTAssertEqual(h.physicalCloses, 1); XCTAssertTrue(recorder.events.isEmpty)
        h.linked = false; await h.advance(0.25)
        XCTAssertEqual(recorder.events.map(\.kind), [.departedFromMac(destination: nil)])
        await h.stop(model)
    }

    @MainActor func testStopDuringNoncooperativePhysicalReleaseFencesLateDeparture() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let (model, recorder) = await start(h)
        await h.acquire(model)
        h.holdClose = true; h.notify(.background); await h.settle()
        model.stop(); await h.settle()
        h.holdClose = false; h.closeGate?.resume(); h.closeGate = nil
        await h.settle()
        XCTAssertTrue(recorder.events.isEmpty); XCTAssertFalse(model.enabled)
        await h.stop(model)
    }

    @MainActor func testProvenRemoteDepartureSurvivesIntentionalCloseAndSilentColdBootstrap() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let (model, recorder) = await start(h)
        await h.acquire(model)
        h.notify(.background); await h.settle()
        XCTAssertEqual(recorder.events.map(\.kind), [.departedFromMac(destination: nil)])
        XCTAssertFalse(h.linked); XCTAssertFalse(h.open)
        await h.advance(3)
        h.play(); await h.advance(0.2)
        // The cold bootstrap emits background with no stream. It must not
        // invent remote proof or erase the preceding verified departure.
        XCTAssertEqual(recorder.events.count, 1)
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        XCTAssertEqual(recorder.events.map(\.kind),
                       [.departedFromMac(destination: nil), .acquiredFromOtherDevice])
        await h.stop(model)
    }
}
