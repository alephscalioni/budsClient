import XCTest
@testable import BudsAutoSwitch

final class NativeUnknownPlaybackGuardPolicyTests: XCTestCase {
    func testContinuousWindowAcceptsFalseAndUnknownButResetsOnEveryVeto() {
        for media: Bool? in [false, nil] {
            var p = NativeUnknownPlaybackGuardPolicy()
            XCTAssertFalse(p.observe(at: 0, halOutput: true, mediaPlaying: media, eligible: true))
            XCTAssertFalse(p.observe(at: 1.99, halOutput: true, mediaPlaying: media, eligible: true))
            XCTAssertTrue(p.observe(at: 2, halOutput: true, mediaPlaying: media, eligible: true))
            for veto in 0..<3 {
                XCTAssertFalse(p.observe(at: 3, halOutput: veto != 0,
                    mediaPlaying: veto == 1 ? true : media, eligible: veto != 2))
                XCTAssertFalse(p.isObserving)
                XCTAssertFalse(p.observe(at: 4, halOutput: true, mediaPlaying: media, eligible: true))
            }
            p.reset(); XCTAssertFalse(p.isObserving)
        }
    }

    func testClockRegressionAndNonFiniteTimeCannotExpireWindow() {
        var p = NativeUnknownPlaybackGuardPolicy()
        XCTAssertFalse(p.observe(at: 10, halOutput: true, mediaPlaying: nil, eligible: true))
        XCTAssertFalse(p.observe(at: 9, halOutput: true, mediaPlaying: nil, eligible: true))
        XCTAssertFalse(p.observe(at: 10.9, halOutput: true, mediaPlaying: nil, eligible: true))
        XCTAssertFalse(p.observe(at: .infinity, halOutput: true, mediaPlaying: nil, eligible: true))
        XCTAssertFalse(p.isObserving)
    }
}

/// All effects and elapsed time are fake; no player, audio, radio or journal IO.
final class NativeUnknownPlaybackGuardControllerTests: XCTestCase {
    @MainActor private func waiting(connected: Bool = false) async -> (NativeControllerHarness, NativeAutoSwitchModel) {
        let h = NativeControllerHarness()
        h.physicalReleasePolicy = true; h.linked = connected
        return (h, await h.start())
    }

    @MainActor func testShortHALWarmupDoesNotAcquireOrRestoreAndResetsWindow() async {
        let (h, m) = await waiting()
        h.otherOutput = true; await h.advance(0.2); await h.advance(1.8)
        XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0); XCTAssertEqual(h.requests, 0)
        h.otherOutput = false; await h.advance(0.2)
        h.otherOutput = true; await h.advance(0.2); await h.advance(1.8)
        XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0); XCTAssertEqual(h.opens, 0)
        h.otherOutput = false; await h.stop(m)
    }

    @MainActor func testPersistentUnreportedHALReleasesExactlyOnceWithoutPausingOtherClient() async {
        for connected in [false, true] {
            for unknown in [false, true] {
                let (h, m) = await waiting(connected: connected)
                let oldFrame = h.frame, oldFailure = h.failure
                h.sampleIsUnknown = unknown; h.otherOutput = true
                await h.advance(0.2); await h.advance(1.99)
                XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0)
                await h.advance(0.21)
                XCTAssertFalse(h.armed); XCTAssertTrue(m.enabled); XCTAssertFalse(m.busy)
                XCTAssertEqual(h.restores, 1); XCTAssertEqual(h.pauses, 0)
                XCTAssertEqual(h.requests, 0); XCTAssertEqual(h.physicalCloses, 0)
                XCTAssertTrue(h.routeWrites.isEmpty); XCTAssertEqual(h.output, 1)
                XCTAssertFalse(m.nativeChannelOpen)
                XCTAssertTrue(m.status.contains("não informou o status"))
                oldFailure?(NativeBudsError(message: "late old control failure"))
                oldFrame?(.init(command: 0x45, payload: Data(), sequence: 0, isResponse: false, isFragment: false))
                await h.settle()
                XCTAssertTrue(m.enabled); XCTAssertEqual(h.pauses, 0)
                await h.advance(10)
                h.otherOutput = false; h.sampleIsUnknown = false; await h.advance(0.2)
                XCTAssertFalse(h.armed); XCTAssertEqual(h.arms, 1); XCTAssertEqual(h.restores, 1)
                await h.acquire(m) // Still enabled; only a genuine MR edge can reopen.
                XCTAssertTrue(h.armed); XCTAssertEqual(h.requests, 1)
                await h.stop(m)
            }
        }
    }

    @MainActor func testMediaRemoteArrivingWithinWindowKeepsProtectionThroughRequestAndOwnership() async {
        let (h, m) = await waiting()
        h.otherOutput = true; h.sampleIsUnknown = true
        await h.advance(0.2); await h.advance(1.5)
        h.sampleIsUnknown = false; h.play(); await h.advance(0.2)
        await h.advance(3)
        XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0); XCTAssertEqual(h.requests, 1)
        h.notify(); await h.advance(0.15)
        h.sampleIsUnknown = true; await h.advance(3); await h.advance(3)
        XCTAssertEqual(m.route, "Mac"); XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0)
        h.otherOutput = false; await h.stop(m)
    }

    @MainActor func testInputAndCallVetoResetTimerAndDoNotBecomeAcquireIntent() async {
        for call in [false, true] {
            let (h, m) = await waiting(connected: call)
            h.otherOutput = true
            await h.advance(0.2); await h.advance(1)
            if call { h.notify(.background, stream: .hfp) } else { h.inputActive = true }
            await h.advance(0.2); await h.advance(3)
            XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0); XCTAssertEqual(h.requests, 0)
            if call { h.notify(.background, stream: []) } else { h.inputActive = false }
            await h.advance(0.2)
            XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0)
            h.otherOutput = false; await h.stop(m)
        }
    }

    @MainActor func testVerificationManualRouteAndRestoreFailuresKeepGuardWithoutPauseOrJournalClear() async {
        for failure in 0..<3 {
            let (h, m) = await waiting()
            h.otherOutput = true; await h.advance(0.2)
            if failure == 0 { h.verifyError = "guard ownership changed" }
            if failure == 1 { h.output = 3 }
            if failure == 2 { h.restoreError = "journal ownership changed" }
            await h.advance(2.2)
            XCTAssertFalse(m.enabled); XCTAssertTrue(m.recoveryPending); XCTAssertTrue(h.armed)
            XCTAssertEqual(h.pauses, 0); XCTAssertEqual(h.restores, failure == 2 ? 1 : 0)
            XCTAssertTrue(h.routeWrites.isEmpty); XCTAssertEqual(h.requests, 0)
            await h.advance(30); XCTAssertTrue(h.armed)
            h.otherOutput = false; h.verifyError = nil; h.restoreError = nil
            await h.stop(m)
        }
    }

    @MainActor func testStopAndRestartDoNotCarryPartiallyElapsedWindow() async {
        let (h, m) = await waiting()
        h.otherOutput = true; await h.advance(0.2); await h.advance(1.5)
        h.otherOutput = false; await h.stop(m)
        m.start(transportGranted: true); await h.settle()
        let restores = h.restores
        h.otherOutput = true; await h.advance(0.2); await h.advance(1)
        XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, restores)
        await h.advance(1.2)
        XCTAssertFalse(h.armed); XCTAssertEqual(h.restores, restores + 1)
        h.otherOutput = false; await h.stop(m)
    }

    @MainActor func testInputStartingDuringMediaRemoteSampleVetoesDueRestore() async {
        let (h, m) = await waiting()
        h.otherOutput = true; await h.advance(0.2)
        h.sampleHook = { h.inputActive = true }
        await h.advance(2.2)
        XCTAssertTrue(m.enabled); XCTAssertTrue(h.armed)
        XCTAssertEqual(h.restores, 0); XCTAssertEqual(h.requests, 0); XCTAssertEqual(h.pauses, 0)
        h.sampleHook = nil; h.inputActive = false
        await h.advance(0.2); await h.advance(1)
        XCTAssertTrue(h.armed)
        h.otherOutput = false; await h.stop(m)
    }

    @MainActor func testFailedVerificationDoesNotAutomaticallyPauseOrRestoreOnDeinit() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
        var m: NativeAutoSwitchModel? = await h.start()
        weak var weakModel = m
        h.otherOutput = true; await h.advance(0.2)
        h.verifyError = "guard verification failed"; await h.advance(2.2)
        XCTAssertFalse(m!.enabled); XCTAssertTrue(m!.recoveryPending)
        m = nil; await h.settle()
        XCTAssertNil(weakModel); XCTAssertTrue(h.armed)
        XCTAssertEqual(h.pauses, 0); XCTAssertEqual(h.restores, 0)
    }

    @MainActor func testRealGuardRestoresOriginalMuteAndPreservesForeignJournalOnVerificationFailure() async {
        for originalMute: UInt32 in [0, 1] {
            for replaceJournal in [false, true] {
                let h = NativeControllerHarness(); h.physicalReleasePolicy = true; h.linked = false
                let journal = UnknownPlaybackMemoryJournal()
                var mute = originalMute
                let state = SpeakerGuardState(environment: SpeakerGuardEnvironment(journal: journal, pid: 100,
                    isAlive: { _ in true }, uid: { _ in "waiting-output" }, resolve: { _ in 1 },
                    mute: { _ in mute }, setMute: { _, value in mute = value }, startWatchdog: { _ in }))
                var env = h.environment()
                env.isArmed = { state.record != nil }
                env.armedDevice = { state.device }
                env.arm = { try state.arm($0) }
                env.verify = { try state.verify() }
                env.restore = { h.restores += 1; try state.restore() }
                let m = NativeAutoSwitchModel(environment: env)
                await m.refresh(); m.start(transportGranted: true); await h.settle()
                XCTAssertEqual(mute, 1); XCTAssertNotNil(journal.entry)
                h.otherOutput = true; await h.advance(0.2)
                let foreign = SpeakerGuardRecord(deviceUID: "waiting-output", originalMute: originalMute,
                    ownerPID: 200, token: UUID().uuidString)
                if replaceJournal { journal.entry = foreign }
                await h.advance(2.2)
                XCTAssertEqual(h.pauses, 0); XCTAssertTrue(h.routeWrites.isEmpty)
                if replaceJournal {
                    XCTAssertEqual(journal.entry, foreign); XCTAssertEqual(journal.removals, 0)
                    XCTAssertEqual(mute, 1); XCTAssertTrue(m.recoveryPending); XCTAssertFalse(m.enabled)
                    // Return the fake journal to its owner for explicit test cleanup.
                    journal.entry = state.record
                } else {
                    XCTAssertNil(journal.entry); XCTAssertEqual(journal.removals, 1)
                    XCTAssertEqual(mute, originalMute); XCTAssertTrue(m.enabled)
                }
                h.otherOutput = false; await h.stop(m)
            }
        }
    }
}

private final class UnknownPlaybackMemoryJournal: SpeakerGuardJournal {
    var entry: SpeakerGuardRecord?
    var removals = 0
    func withLock(_ action: () throws -> Void) throws { try action() }
    func read() throws -> SpeakerGuardRecord? { entry }
    func write(_ record: SpeakerGuardRecord) throws { entry = record }
    func remove() throws { removals += 1; entry = nil }
}
