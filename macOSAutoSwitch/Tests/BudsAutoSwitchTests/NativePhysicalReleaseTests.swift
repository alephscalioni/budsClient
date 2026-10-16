import XCTest
@testable import BudsAutoSwitch

/// The same optional effect configured by live(), entirely fake host effects.
final class NativePhysicalReleaseTests: XCTestCase {
    @MainActor func testAndroidMetadataRequestCanBeIsolatedFromSettingInfoAndAccountConfiguration() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
        let model = await h.start()
        model.laboratoryAndroidMetadataRequest = true
        h.play(); await h.advance(0.2)
        XCTAssertTrue(h.commands.contains(SamsungMdePacket.settingInfoClassicBluetooth()))
        XCTAssertFalse(h.commands.contains(SamsungMdePacket.settingInfoMobileCompatibilityBluetooth()))
        XCTAssertTrue(h.commands.contains(SamsungMdePacket.configureVersion3()))
        XCTAssertTrue(h.commands.contains(SamsungMdePacket.requestAndroidMetadataSwitch()))
        XCTAssertFalse(h.commands.contains(SamsungMdePacket.requestMobileCompatibilitySwitch()))
        XCTAssertFalse(h.commands.contains(SamsungMdePacket.requestComputerSwitch()))
        XCTAssertEqual(model.transportDiagnostics["mde_request_variant"] as? String, "android_metadata_empty")
        await h.stop(model)
    }
    @MainActor func testOwnedConfigurationIsUsedBeforeAcquisitionWithoutBareFallback() async throws {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
        let model = await h.start()
        let owned = try SamsungMdePacket.configureOwnedAccountVersion3(accountFingerprint: Data(0...31))
        model.ownedMDEConfiguration = { owned }
        await h.acquire(model)
        XCTAssertTrue(h.commands.contains(owned))
        XCTAssertFalse(h.commands.contains(SamsungMdePacket.configureVersion3()))
        XCTAssertEqual(model.transportDiagnostics["mde_account_configuration_submitted"] as? Bool, true)
        await h.stop(model)
    }

    @MainActor func testManualRouteChangeDuringAccountConfigurationWaitSendsNoSetupOrRequest() async throws {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
        let model = await h.start()
        var gate: CheckedContinuation<Data, Error>?
        model.ownedMDEConfiguration = { try await withCheckedThrowingContinuation { gate = $0 } }
        h.play(); await h.advance(0.2); XCTAssertNotNil(gate)
        h.output = 3
        gate?.resume(returning: try SamsungMdePacket.configureOwnedAccountVersion3(accountFingerprint: Data(0...31)))
        gate = nil; await h.settle()
        XCTAssertEqual(h.requests, 0)
        XCTAssertFalse(h.commands.contains(SamsungMdePacket.settingInfoClassicBluetooth()))
        XCTAssertFalse(model.enabled); XCTAssertEqual(h.output, 3); XCTAssertFalse(h.armed)
        await h.stop(model)
    }
    @MainActor func testManualRouteChangeInsideFinalSettlementSampleCannotSubmitClose() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        h.remoteReleaseSettleDelay = 2; h.linked = false
        let model = await h.start(); await h.acquire(model)
        h.notify(.background); await h.settle()
        h.sampleHook = { h.output = 3 }
        await h.advance(2.1)
        XCTAssertEqual(h.physicalCloses, 0); XCTAssertEqual(h.output, 3)
        XCTAssertFalse(model.enabled); XCTAssertFalse(h.armed)
        h.sampleHook = nil; await h.stop(model)
    }

    @MainActor func testAccountRefreshRotatesModelAnnouncementAndYieldReceiptTogether() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
        let model = await h.start()
        var acquired: [UUID] = [], yielded: [UUID] = []
        model.onMacAcquired = { epoch, _ in acquired.append(epoch) }
        model.onMacYieldPrepared = { epoch, _ in yielded.append(epoch) }
        await h.acquire(model); XCTAssertEqual(acquired.count, 1)
        XCTAssertTrue(model.refreshPeerOwnershipAnnouncement()); XCTAssertEqual(acquired.count, 2)
        XCTAssertNotEqual(acquired[0], acquired[1])
        h.notify(.background); await h.settle()
        XCTAssertEqual(yielded, [acquired[1]])
        XCTAssertFalse(model.refreshPeerOwnershipAnnouncement(), "phone ownership cannot reannounce Mac")
        await h.stop(model)
    }
    @MainActor func testNewPlaybackDuringYieldRouteCannotAttestPausedPlayer() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
        let model = await h.start(); await h.acquire(model)
        var receipts = 0; model.onMacYieldPrepared = { _, _ in receipts += 1 }
        h.holdRoute = true; h.notify(.background); await h.settle()
        XCTAssertNotNil(h.routeGate); XCTAssertFalse(h.playing)
        h.play()
        h.holdRoute = false; h.routeGate?.resume(); h.routeGate = nil
        await h.settle()
        XCTAssertEqual(receipts, 0); XCTAssertEqual(h.physicalCloses, 0); XCTAssertTrue(h.playing)
        await h.stop(model)
    }
    @MainActor func testNativeTwoSecondRouteSettlementKeepsGuardThenClosesAndConfirmsAbsence() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        h.remoteReleaseSettleDelay = 2; h.linked = false
        let model = await h.start(); await h.acquire(model)
        var prepared = 0
        model.onMacYieldPrepared = { _, _ in
            XCTAssertFalse(h.playing); XCTAssertTrue(h.armed); XCTAssertEqual(h.output, 1)
            prepared += 1
        }
        h.notify(.background); await h.settle()
        XCTAssertEqual(prepared, 1)
        XCTAssertEqual(h.physicalCloses, 0); XCTAssertTrue(h.armed); XCTAssertFalse(h.playing)
        XCTAssertTrue(model.nativeChannelOpen)
        await h.advance(1.9); XCTAssertEqual(h.physicalCloses, 0)
        await h.advance(0.2)
        XCTAssertEqual(h.physicalCloses, 1); XCTAssertFalse(h.linked)
        XCTAssertEqual(model.route, "Galaxy"); XCTAssertTrue(h.armed)
        await h.stop(model); XCTAssertFalse(h.armed)
    }

    @MainActor func testSettlementNewPlayCallManualRouteOrStopCannotIssueOldClose() async {
        for action in ["play", "call", "manual", "stop"] {
            let h = NativeControllerHarness(); h.physicalReleasePolicy = true
            h.remoteReleaseSettleDelay = 2; h.linked = false
            let model = await h.start(); await h.acquire(model)
            h.notify(.background); await h.settle(); await h.advance(0.5)
            switch action {
            case "play": h.play()
            case "call": h.notify(.background, stream: .hfp)
            case "manual": h.output = 3
            default: model.stop()
            }
            await h.advance(0.2)
            await h.advance(2.1)
            XCTAssertEqual(h.physicalCloses, 0, action)
            XCTAssertNotEqual(model.route, "Galaxy", action)
            if action == "manual" { XCTAssertEqual(h.output, 3) }
            await h.stop(model); XCTAssertFalse(h.armed)
        }
    }
    @MainActor private func cold() async -> (NativeControllerHarness, NativeAutoSwitchModel) {
        let h = NativeControllerHarness()
        h.physicalReleasePolicy = true; h.linked = false
        return (h, await h.start())
    }

    @MainActor private func events(_ model: NativeAutoSwitchModel) -> [String] {
        (model.transportDiagnostics["controller_events"] as? [[String: Any]] ?? [])
            .compactMap { $0["event"] as? String }
    }

    @MainActor func testFiveColdCyclesReleaseThenWaitWithoutIdleReopen() async {
        let (h, model) = await cold()
        XCTAssertTrue(h.armed, "Live silent wait must pre-arm before the first play poll")
        XCTAssertFalse(model.nativeChannelOpen)
        XCTAssertEqual(h.opens, 0)
        for cycle in 1...5 {
            await h.acquire(model)
            XCTAssertTrue(model.nativeChannelOpen)
            h.notify(.background, stream: []) // background alone is not remote playback
            await h.settle()
            XCTAssertEqual(h.physicalCloses, cycle - 1)
            let linkReads = h.linkReads
            h.notify(.background)
            await h.settle()
            XCTAssertEqual(h.physicalCloses, cycle)
            XCTAssertEqual(h.opens, cycle); XCTAssertEqual(h.requests, cycle)
            XCTAssertFalse(h.linked); XCTAssertFalse(model.nativeChannelOpen)
            XCTAssertGreaterThan(h.linkReads, linkReads, "Every completed release needs a fresh link observation")
            XCTAssertTrue(model.enabled); XCTAssertTrue(h.armed); XCTAssertFalse(model.busy)
            XCTAssertEqual(h.output, 1); XCTAssertEqual(model.route, "Galaxy")
            XCTAssertEqual(model.transportDiagnostics["control_prepared"] as? Bool, false)
            XCTAssertEqual(model.transportDiagnostics["physical_link_absent_observed"] as? Bool, true)
            let proof = events(model)
            let prerequisites = proof.lastIndex(of: "physical_release_prerequisites_confirmed")!
            let closed = proof.lastIndex(of: "physical_close_returned")!
            let observed = proof.lastIndex(of: "physical_link_absent_observed")!
            XCTAssertLessThan(prerequisites, closed); XCTAssertLessThan(closed, observed)
            await h.advance(30)
            XCTAssertEqual(h.opens, cycle, "Idle time cannot reopen after full release")
        }
        XCTAssertEqual(h.commands.filter { $0 == SamsungMdePacket.settingInfoClassicBluetooth() }.count, 5)
        await h.stop(model)
        XCTAssertFalse(h.armed); XCTAssertFalse(model.enabled)
    }

    @MainActor func testAlreadyPlayingAtEnableKeepsBaselineUntilPauseThenPrearms() async {
        for connected in [false, true] {
            let h = NativeControllerHarness(); h.physicalReleasePolicy = true
            h.linked = connected; h.playing = true
            let model = await h.start()
            XCTAssertFalse(h.armed); XCTAssertTrue(h.playing); XCTAssertEqual(h.opens, 0)
            await h.advance(1); XCTAssertEqual(h.requests, 0)
            h.playing = false; await h.advance(0.2)
            XCTAssertTrue(h.armed)
            await h.acquire(model)
            await h.stop(model)
        }
    }

    @MainActor func testPrearmPrecedesSlowDiscoveryAndDoesNotConnect() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        h.linked = false; h.holdLink = true
        let model = await h.start()
        XCTAssertTrue(h.armed); XCTAssertNotNil(h.linkGate); XCTAssertEqual(h.opens, 0)
        h.play() // the guard already owns the waiting output before any poll
        h.holdLink = false; h.linkGate?.resume(); h.linkGate = nil
        await h.settle()
        XCTAssertEqual(h.requests, 1)
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        await h.stop(model)
    }

    @MainActor func testNoRemoteStreamAndNoExplicitPauseCannotPhysicallyClose() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.sampleIsUnknown = true
        h.notify(.background); await h.settle()
        XCTAssertEqual(h.physicalCloses, 0)
        XCTAssertTrue(model.error?.contains("pausa") == true)
        h.sampleIsUnknown = false
        await h.stop(model)
    }

    @MainActor func testCloseReturnDoesNotProveLinkAbsent() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.closeDropsLink = false
        h.notify(.background); await h.settle()
        XCTAssertEqual(h.physicalCloses, 1)
        XCTAssertFalse(model.nativeChannelOpen)
        XCTAssertEqual(model.transportDiagnostics["physical_link_absent_observed"] as? Bool, false)
        XCTAssertNotEqual(model.route, "Galaxy")
        XCTAssertFalse(events(model).contains("physical_link_absent_observed"))
        h.linked = false; await h.advance(0.25)
        XCTAssertEqual(model.route, "Galaxy")
        XCTAssertTrue(h.armed); XCTAssertTrue(model.enabled)
        await h.stop(model)
    }

    @MainActor func testNewPlayWaitsForNoncooperativeCloseThenColdBootstraps() async {
        let (h, model) = await cold()
        await h.acquire(model)
        let staleFailure = h.failure, staleFrame = h.frame
        h.holdClose = true; h.notify(.background); await h.settle()
        XCTAssertNotNil(h.closeGate); XCTAssertTrue(model.transportIsSettling)
        h.play(); await h.advance(3)
        XCTAssertTrue(h.playing); XCTAssertTrue(h.armed); XCTAssertEqual(h.output, 1)
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.requests, 1)
        staleFailure?(NativeBudsError(message: "intentional-close-must-be-fenced"))
        h.frame = staleFrame; h.notify(.foreground); h.frame = nil
        XCTAssertNil(model.error)
        h.holdClose = false; h.closeGate?.resume(); h.closeGate = nil
        await h.settle(); await h.advance(0.2)
        XCTAssertEqual(h.opens, 2); XCTAssertEqual(h.requests, 2)
        XCTAssertEqual(h.hud, ["Conectado ao Mac"], "A superseded yield must not announce Galaxy after the new play")
        XCTAssertTrue(h.playing); XCTAssertEqual(h.output, 1)
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        await h.stop(model)
    }

    @MainActor func testPauseDuringCloseCancelsPendingPlayAndKeepsPauseBaseline() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.holdClose = true; h.notify(.background); await h.settle()
        h.play(); await h.advance(3)
        h.playing = false; await h.advance(0.2)
        h.holdClose = false; h.closeGate?.resume(); h.closeGate = nil
        await h.settle(); await h.advance(1)
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.requests, 1)
        await h.acquire(model)
        XCTAssertEqual(h.opens, 2)
        await h.stop(model)
    }

    @MainActor func testStopOrManualRouteDuringCloseFencesLateResultAndRestores() async {
        for manualOutput: UInt32? in [nil, 2, 3] {
            let (h, model) = await cold()
            await h.acquire(model)
            h.holdClose = true; h.notify(.background); await h.settle()
            if let manualOutput { h.output = manualOutput; await h.advance(0.2) }
            else { model.stop(); await h.settle() }
            XCTAssertFalse(model.enabled); XCTAssertFalse(h.armed)
            XCTAssertTrue(model.transportIsSettling)
            model.start(transportGranted: true)
            h.holdClose = false; h.closeGate?.resume(); h.closeGate = nil
            await h.settle(); await h.advance(30)
            XCTAssertFalse(model.transportIsSettling); XCTAssertFalse(model.busy)
            XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.requests, 1)
            XCTAssertNotEqual(model.route, "Galaxy")
            XCTAssertFalse(events(model).contains("physical_link_absent_observed"))
            XCTAssertEqual(h.output, manualOutput ?? 1)
            await h.stop(model)
        }
    }

    @MainActor func testCallBeforeReleaseDefersCloseUntilRemoteMedia() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.notify(.background, stream: .hfp); await h.settle()
        XCTAssertEqual(h.physicalCloses, 0)
        h.play(); await h.advance(3)
        XCTAssertEqual(h.requests, 1)
        h.notify(.background); await h.settle()
        XCTAssertEqual(h.physicalCloses, 1)
        XCTAssertFalse(h.linked)
        await h.advance(3); XCTAssertEqual(h.requests, 1)
        await h.acquire(model)
        await h.stop(model)
    }

    @MainActor func testCallInputDuringCloseConsumesPlayAndNewBootstrapCallVetoesRequest() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.holdClose = true; h.notify(.background); await h.settle()
        h.inputActive = true; h.play(); await h.advance(3)
        h.holdClose = false; h.closeGate?.resume(); h.closeGate = nil
        await h.settle(); await h.advance(0.2)
        XCTAssertEqual(h.opens, 1)
        XCTAssertEqual(h.hud, ["Conectado ao Mac"], "A call during close must fence the old remote HUD")
        h.inputActive = false; await h.advance(0.2)
        XCTAssertEqual(h.opens, 1, "Call ending cannot replay a suppressed edge")
        h.playing = false; await h.advance(0.2)
        h.bootstrapCall = true
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.opens, 2); XCTAssertEqual(h.requests, 1)
        XCTAssertFalse(h.playing)
        h.bootstrapCall = false; h.notify(.background, stream: [])
        await h.advance(3)
        XCTAssertEqual(h.requests, 1)
        await h.acquire(model)
        await h.stop(model)
    }

    @MainActor func testColdControlRechecksPauseAfterBootstrapBeforeRequest() async {
        let (h, model) = await cold()
        h.bootstrapState = false
        h.openHook = { h.playing = false }
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.requests, 0)
        h.openHook = nil; h.notify(.background, stream: [])
        await h.advance(0.15)
        XCTAssertEqual(h.requests, 0)
        await h.acquire(model)
        await h.stop(model)
    }

    @MainActor func testCloseErrorAndObservationErrorRestoreAndDoNotReopenIdle() async {
        for observationError in [false, true] {
            let (h, model) = await cold()
            await h.acquire(model)
            if observationError { h.linkError = "fresh-observation-failed" }
            else { h.closeError = "physical-close-failed" }
            h.notify(.background); await h.settle()
            XCTAssertFalse(h.armed); XCTAssertTrue(model.enabled)
            XCTAssertNotNil(model.error); XCTAssertEqual(h.physicalCloses, 1)
            h.linkError = nil; h.closeError = nil
            await h.advance(1); await h.advance(30)
            XCTAssertEqual(h.opens, 1); XCTAssertFalse(h.armed)
            XCTAssertEqual(model.transportDiagnostics["physical_link_absent_observed"] as? Bool, false)
            await h.acquire(model)
            await h.stop(model)
        }
    }

    @MainActor func testCloseTimeoutRestoresBeforeDrainAndNeverOverlapsNewOpen() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.holdClose = true; h.notify(.background); await h.settle()
        await h.advance(12)
        XCTAssertTrue(model.enabled); XCTAssertFalse(h.armed)
        XCTAssertTrue(model.transportIsSettling); XCTAssertTrue(model.busy)
        XCTAssertTrue(model.error?.contains("doze segundos") == true)
        h.play(); await h.advance(30)
        XCTAssertEqual(h.opens, 1); XCTAssertTrue(h.playing)
        h.holdClose = false; h.closeGate?.resume(); h.closeGate = nil
        await h.settle(); await h.advance(1)
        XCTAssertFalse(model.transportIsSettling); XCTAssertFalse(h.armed)
        XCTAssertEqual(h.opens, 1)
        h.playing = false; await h.advance(0.2)
        await h.acquire(model)
        await h.stop(model)
    }

    @MainActor func testLinkStaysPresentTimesOutWithoutFalseAbsence() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.closeDropsLink = false; h.notify(.background); await h.settle()
        await h.advance(12); await h.advance(1); await h.advance(30)
        XCTAssertTrue(model.enabled); XCTAssertFalse(h.armed)
        XCTAssertFalse(events(model).contains("physical_link_absent_observed"))
        XCTAssertEqual(h.opens, 1)
        await h.stop(model)
    }

    @MainActor func testUnavailableColdOpenHasOneTwelveSecondBudgetAndRestoresPrearm() async {
        let (h, model) = await cold()
        h.holdOpen = true
        h.play(); await h.advance(0.2)
        await h.advance(12); await h.advance(1); await h.advance(30)
        XCTAssertTrue(model.enabled); XCTAssertFalse(h.armed); XCTAssertFalse(h.playing)
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.requests, 0)
        XCTAssertTrue(model.error?.contains("doze segundos") == true)
        await h.stop(model)
    }

    @MainActor func testFreshObservationTimeoutFencesLateAbsentReading() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.holdLink = true
        h.notify(.background); await h.settle()
        XCTAssertNotNil(h.linkGate); XCTAssertEqual(h.physicalCloses, 1)
        await h.advance(12)
        XCTAssertTrue(model.enabled); XCTAssertFalse(h.armed)
        XCTAssertTrue(model.transportIsSettling)
        h.holdLink = false; h.linkGate?.resume(); h.linkGate = nil
        await h.settle(); await h.advance(1)
        XCTAssertFalse(events(model).contains("physical_link_absent_observed"))
        XCTAssertEqual(h.opens, 1)
        await h.stop(model)
    }

    @MainActor func testNewPlayDuringWaitingRouteAbortsPhysicalReleaseWithoutLostIntent() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.holdRoute = true
        h.notify(.background); await h.settle()
        XCTAssertFalse(h.playing); XCTAssertNotNil(h.routeGate)
        h.play()
        h.holdRoute = false; h.routeGate?.resume(); h.routeGate = nil
        await h.settle(); await h.advance(3)
        XCTAssertEqual(h.physicalCloses, 0)
        XCTAssertEqual(h.requests, 2); XCTAssertTrue(h.playing)
        XCTAssertEqual(h.output, 1); XCTAssertTrue(h.armed)
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        await h.stop(model)
    }

    @MainActor func testIdleReleaseTimeoutRestoresWithoutRequiringAnUnnecessaryPauseACK() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.holdClose = true; h.notify(.background); await h.settle()
        h.pauseError = "pause-not-confirmed"
        await h.advance(12)
        XCTAssertTrue(model.enabled); XCTAssertFalse(model.recoveryPending)
        XCTAssertFalse(h.armed); XCTAssertEqual(h.restores, 1)
        h.holdClose = false; h.closeGate?.resume(); h.closeGate = nil
        await h.settle()
        h.pauseError = nil; await h.stop(model)
        XCTAssertFalse(h.armed); XCTAssertFalse(model.recoveryPending)
        XCTAssertEqual(h.opens, 1)
    }

    @MainActor func testManualOutputDuringInitialDiscoveryPreventsAnyOpen() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        h.holdLink = true
        let model = await h.start()
        XCTAssertTrue(h.armed)
        h.output = 3
        h.holdLink = false; h.linkGate?.resume(); h.linkGate = nil
        await h.settle()
        XCTAssertEqual(h.opens, 0); XCTAssertFalse(model.enabled)
        XCTAssertFalse(h.armed); XCTAssertEqual(h.output, 3)
        await h.stop(model)
    }

    @MainActor func testOldCallbacksCannotAffectReopenedSessionOrLeakIdentifiersIntoProof() async {
        let (h, model) = await cold()
        await h.acquire(model)
        let staleFrame = h.frame, staleFailure = h.failure
        h.notify(.background); await h.settle(); await h.advance(3)
        await h.acquire(model)
        staleFailure?(NativeBudsError(message: "obsolete-callback"))
        let current = h.frame
        h.frame = staleFrame; h.notify(.background, stream: .hfp); h.frame = current
        await h.advance(0.2)
        XCTAssertNil(model.error); XCTAssertEqual(model.route, "Mac")
        XCTAssertEqual(h.physicalCloses, 1); XCTAssertTrue(model.nativeChannelOpen)
        let proof = model.transportDiagnostics["controller_events"] as? [[String: Any]] ?? []
        let text = String(describing: proof)
        XCTAssertFalse(text.contains("AA:BB:CC:DD:EE:FF"))
        XCTAssertFalse(text.lowercased().contains("account"))
        await h.stop(model)
    }

    @MainActor func testColdBootstrapWritesFirstButCannotOwnWithoutFreshNotification() async {
        let (h, model) = await cold()
        h.bootstrapState = false
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.requests, 1)
        XCTAssertNotEqual(model.route, "Mac"); XCTAssertEqual(h.output, 1)
        await h.advance(12); await h.advance(1); await h.advance(30)
        XCTAssertEqual(h.requests, 1); XCTAssertEqual(h.opens, 1)
        XCTAssertTrue(model.enabled); XCTAssertFalse(h.armed)
        await h.stop(model)
    }

    @MainActor func testColdReconnectWaitsForTransportDrainAndRechecksIntentBeforeOpen() async {
        let (h, model) = await cold()
        await h.acquire(model)
        h.notify(.background); await h.settle(); await h.advance(3)
        h.pendingOperations = 1
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.requests, 1)
        h.playing = false; h.pendingOperations = 0; await h.advance(0.1)
        XCTAssertEqual(h.opens, 1, "A pause while the old RFCOMM close drains must prevent a new open")
        await h.advance(0.2)
        await h.acquire(model)
        XCTAssertEqual(h.opens, 2)
        await h.stop(model)
    }

    @MainActor func testInputStartingDuringColdOpenVetoesRequest() async {
        let (h, model) = await cold()
        h.openHook = { h.inputActive = true }
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.requests, 0)
        h.openHook = nil; h.inputActive = false; await h.advance(0.2)
        XCTAssertEqual(h.requests, 0)
        h.playing = false; await h.advance(0.2)
        await h.acquire(model)
        await h.stop(model)
    }

    @MainActor func testCallArrivingAtReleasePrerequisitesPostponesClose() async {
        let (h, model) = await cold()
        await h.acquire(model)
        // Install the one-shot sample hook only after the waiting route has
        // committed, so the call arrives in physical release's own validation.
        h.routeHook = {
            guard h.output == 1 else { return }
            h.sampleHook = {
                h.sampleHook = nil
                h.notify(.background, stream: .hfp)
            }
        }
        h.notify(.background); await h.settle()
        XCTAssertEqual(h.physicalCloses, 0); XCTAssertTrue(model.enabled)
        h.routeHook = nil
        h.notify(.background); await h.settle()
        XCTAssertEqual(h.physicalCloses, 1)
        XCTAssertEqual(model.route, "Galaxy"); XCTAssertFalse(h.linked)
        await h.stop(model)
    }
}
