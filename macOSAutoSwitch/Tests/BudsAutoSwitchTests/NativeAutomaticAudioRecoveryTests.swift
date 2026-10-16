import XCTest
@testable import BudsAutoSwitch

/// Injected effects and virtual time only; never constructs live services.
final class NativeAutomaticAudioRecoveryTests: XCTestCase {
    @MainActor private func start(_ h: NativeControllerHarness,
                                  edit: (inout NativeSwitchEnvironment) -> Void = { _ in }) async -> NativeAutoSwitchModel {
        var environment = h.environment()
        edit(&environment)
        let model = NativeAutoSwitchModel(environment: environment)
        await model.refresh()
        model.start(transportGranted: true)
        await h.settle()
        return model
    }

    @MainActor func testUnknownIdleRecoversWithoutPauseACKOrHeadsetReopen() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await start(h)
        h.sampleIsUnknown = true; h.pauseError = "unknown player"
        h.loseChannel(); await h.settle()
        XCTAssertFalse(h.armed); XCTAssertEqual(h.restores, 1)
        XCTAssertEqual(h.pauses, 0); XCTAssertTrue(model.enabled)
        await h.advance(20)
        XCTAssertEqual(h.opens, 1); XCTAssertTrue(h.routeWrites.isEmpty)
        await h.stop(model)
    }

    @MainActor func testActivityOrInputAppearingDuringSampleVetoesRestoreUntilLaterIdle() async {
        for input in [false, true] {
            let h = NativeControllerHarness(); h.physicalReleasePolicy = true
            let model = await start(h)
            h.sampleIsUnknown = true
            h.sampleHook = { if input { h.inputActive = true } else { h.otherOutput = true } }
            h.loseChannel(); await h.settle()
            XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0); XCTAssertEqual(h.pauses, 0)
            XCTAssertTrue(model.enabled); XCTAssertTrue(model.recoveryPending)
            h.sampleHook = nil; h.otherOutput = false; h.inputActive = false
            await h.advance(1)
            XCTAssertFalse(h.armed); XCTAssertEqual(h.restores, 1)
            XCTAssertEqual(h.pauses, 0); XCTAssertEqual(h.opens, 1)
            await h.stop(model)
        }
    }

    @MainActor func testFailedLocalPauseKeepsMuteAndLaterIdleAutomaticallyRetriesWithoutAnotherPause() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await start(h)
        h.play(); h.pauseError = "pause rejected"
        h.loseChannel(); await h.settle()
        XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0); XCTAssertEqual(h.pauses, 1)
        XCTAssertTrue(model.enabled); XCTAssertTrue(model.recoveryPending)
        await h.advance(1); await h.advance(1)
        XCTAssertEqual(h.pauses, 1); XCTAssertEqual(h.restores, 0); XCTAssertEqual(h.opens, 1)
        h.playing = false; h.sampleIsUnknown = true
        await h.advance(1)
        XCTAssertFalse(h.armed); XCTAssertEqual(h.restores, 1); XCTAssertEqual(h.pauses, 1)
        XCTAssertTrue(model.enabled)
        await h.stop(model)
    }

    @MainActor func testStopWhileRecoverySampleAwaitsCannotRestoreStaleObservationOrReconnect() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        var gate: CheckedContinuation<Void, Never>?
        var hold = false
        let model = await start(h) { environment in
            environment.sample = {
                if hold { await withCheckedContinuation { gate = $0 } }
                return MacPlaybackIntent(isPlaying: nil, clientID: nil, revision: 0)
            }
        }
        hold = true; h.loseChannel(); await h.settle()
        XCTAssertNotNil(gate)
        model.stop(); h.inputActive = true
        hold = false; gate?.resume(); gate = nil
        await h.settle()
        XCTAssertFalse(model.enabled); XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0)
        h.inputActive = false; await h.advance(1); await h.advance(30)
        XCTAssertFalse(h.armed); XCTAssertFalse(model.enabled); XCTAssertEqual(h.opens, 1)
        XCTAssertEqual(h.pauses, 0)
    }

    @MainActor func testDeviceChangeDuringRecoveryAwaitCannotReconnectOldDevice() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await start(h)
        h.otherOutput = true; h.sampleIsUnknown = true
        h.loseChannel(); await h.settle()
        model.selectedBuds = "another-device"
        h.otherOutput = false; await h.advance(1); await h.advance(30)
        XCTAssertFalse(h.armed); XCTAssertEqual(h.opens, 1); XCTAssertTrue(h.routeWrites.isEmpty)
        await h.stop(model)
    }

    @MainActor func testForeignJournalFailureIsRetriedWithoutClearingOrOverwritingForeignRecord() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let journal = AutomaticRecoveryJournal()
        var mute: UInt32 = 0
        let state = SpeakerGuardState(environment: .init(journal: journal, pid: 100,
            isAlive: { _ in true }, uid: { _ in "original-output" }, resolve: { _ in 1 },
            mute: { _ in mute }, setMute: { _, value in mute = value }, startWatchdog: { _ in }))
        let model = await start(h) { environment in
            environment.isArmed = { state.record != nil }
            environment.armedDevice = { state.device }
            environment.arm = { try state.arm($0); h.armed = true }
            environment.verify = { try state.verify() }
            environment.restore = { h.restores += 1; try state.restore(); h.armed = false }
        }
        let foreign = SpeakerGuardRecord(deviceUID: "original-output", originalMute: 0,
            ownerPID: 200, token: UUID().uuidString)
        journal.entry = foreign; h.sampleIsUnknown = true
        h.loseChannel(); await h.settle(); await h.advance(1); await h.advance(1)
        XCTAssertEqual(journal.entry, foreign); XCTAssertEqual(journal.removals, 0)
        XCTAssertEqual(mute, 1); XCTAssertEqual(h.pauses, 0); XCTAssertEqual(h.opens, 1)
        XCTAssertTrue(model.enabled); XCTAssertTrue(model.recoveryPending)
        journal.entry = state.record // Repair only the injected fixture.
        await h.advance(1)
        XCTAssertNil(journal.entry); XCTAssertEqual(mute, 0)
        await h.stop(model)
    }

    @MainActor func testUnknownOrRemotePlayerWithOutputNeverReceivesPauseDuringRecovery() async {
        for unknown in [false, true] {
            let h = NativeControllerHarness(); h.physicalReleasePolicy = true
            let model = await start(h)
            h.sampleIsUnknown = unknown; h.otherOutput = true
            h.loseChannel(); await h.settle(); await h.advance(2)
            XCTAssertTrue(h.armed); XCTAssertEqual(h.pauses, 0); XCTAssertEqual(h.restores, 0)
            h.otherOutput = false; await h.advance(1)
            XCTAssertFalse(h.armed); XCTAssertEqual(h.pauses, 0)
            await h.stop(model)
        }
    }

    @MainActor func testPositiveIntentWithoutIdentifiedClientNeverReceivesPauseOrRestoration() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        var playing = false
        let model = await start(h) { environment in
            environment.sample = { MacPlaybackIntent(isPlaying: playing, clientID: nil, revision: 0) }
        }
        playing = true; h.loseChannel(); await h.settle(); await h.advance(1)
        XCTAssertTrue(h.armed); XCTAssertEqual(h.pauses, 0); XCTAssertEqual(h.restores, 0)
        playing = false; await h.advance(1)
        XCTAssertFalse(h.armed); await h.stop(model)
    }

    @MainActor func testStopDrainsAcceptedRecoveryRestoreBeforeStartingAnotherCleanup() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        var gate: CheckedContinuation<Void, Never>?
        var hold = true
        let model = await start(h) { environment in
            environment.restore = {
                h.restores += 1
                if hold { await withCheckedContinuation { gate = $0 } }
                h.armed = false
            }
        }
        h.otherOutput = true; h.sampleIsUnknown = true
        h.loseChannel(); await h.settle()
        h.otherOutput = false; await h.advance(1)
        XCTAssertNotNil(gate); XCTAssertEqual(h.restores, 1)
        model.stop(); await h.settle()
        XCTAssertTrue(model.transportIsSettling); XCTAssertEqual(h.restores, 1)
        hold = false; gate?.resume(); gate = nil
        await h.settle(); await h.advance(30)
        XCTAssertFalse(h.armed); XCTAssertFalse(model.enabled)
        XCTAssertFalse(model.transportIsSettling); XCTAssertEqual(h.opens, 1)
    }

    @MainActor func testManualRouteDuringSampleVetoesPauseAndRestoration() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await start(h)
        h.play(); h.sampleHook = { h.output = 3 }
        h.loseChannel(); await h.settle()
        XCTAssertEqual(h.pauses, 0); XCTAssertEqual(h.restores, 0)
        XCTAssertEqual(h.output, 3); XCTAssertTrue(h.armed); XCTAssertTrue(h.routeWrites.isEmpty)
        h.sampleHook = nil; h.playing = false
        await h.advance(1)
        XCTAssertFalse(h.armed); XCTAssertEqual(h.output, 3)
        await h.stop(model)
    }

    @MainActor func testPendingRecoveryDoesNotRetainModelForever() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        var model: NativeAutoSwitchModel? = await start(h)
        h.sampleIsUnknown = true; h.otherOutput = true
        h.loseChannel(); await h.settle()
        weak var released = model
        model = nil; await h.settle()
        XCTAssertNil(released); XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0)
    }
}

private final class AutomaticRecoveryJournal: SpeakerGuardJournal {
    var entry: SpeakerGuardRecord?
    var removals = 0
    func withLock(_ action: () throws -> Void) throws { try action() }
    func read() throws -> SpeakerGuardRecord? { entry }
    func write(_ record: SpeakerGuardRecord) throws { entry = record }
    func remove() throws { removals += 1; entry = nil }
}
