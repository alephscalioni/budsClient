import XCTest
@testable import BudsAutoSwitch

final class MacPlaybackIntentTests: XCTestCase {
    func testOnlyObservedPlaybackChangesAdvanceRevision() {
        var history = PlaybackIntentHistory()
        history.observe(playing: nil, client: nil, item: nil)
        XCTAssertEqual(history.revision, 0)
        history.observe(playing: false, client: "safari", item: "video1")
        XCTAssertEqual(history.revision, 0, "The initial client is a baseline, not a play edge")
        history.observe(playing: true, client: "safari", item: "video1")
        XCTAssertEqual(history.revision, 1)
        for _ in 0..<10 { history.observe(playing: true, client: "safari", item: "video1") }
        history.observe(playing: nil, client: nil, item: nil)
        history.observe(playing: true, client: "safari", item: "video1")
        XCTAssertEqual(history.revision, 1)
        history.observe(playing: false, client: "safari", item: "video1")
        history.observe(playing: true, client: "safari", item: "video1")
        XCTAssertEqual(history.revision, 2)
        history.observe(playing: true, client: "safari", item: "video2")
        XCTAssertEqual(history.revision, 2)
        history.observe(playing: true, client: "music", item: "track")
        XCTAssertEqual(history.revision, 3)
    }

    func testVerifiedReplyBeforePeriodicUpdateReplacesPrePausePlayingState() {
        var cache = PlaybackObservationCache()
        cache.observe(observation(true, at: 10), at: 10)
        cache.beginPause(at: 10.1)
        XCTAssertNil(cache.current(at: 10.1), "Verification must not reuse a pre-command cached true")

        // A read during the command may still report playing before pause settles.
        cache.observe(observation(true, at: 10.2), at: 10.3)
        let verified = observation(false, at: 10.4)
        XCTAssertTrue(cache.acceptPauseReply(ok: true, paused: true, observation: verified,
                                             client: "safari", requestedAt: 10.1, now: 10.5))
        XCTAssertEqual(cache.current(at: 10.5), verified)
    }

    func testDelayedRowsCannotOverwriteVerifiedPauseEvenIfDeliveredLater() {
        var cache = PlaybackObservationCache()
        cache.beginPause(at: 10)
        let verified = observation(false, at: 10.4)
        XCTAssertTrue(cache.acceptPauseReply(ok: true, paused: true, observation: verified,
                                             client: "safari", requestedAt: 10, now: 10.5))
        for uptime in [9.9, 10.2, 10.4] {
            XCTAssertFalse(cache.observe(observation(true, at: uptime), at: 10.6))
            XCTAssertFalse(cache.observe(observation(true, client: "music", at: uptime), at: 10.7))
        }
        XCTAssertEqual(cache.current(at: 10.7), verified)
    }

    func testDelayedPreCommandRowsRemainInvalidAfterCommandFailure() {
        var cache = PlaybackObservationCache()
        cache.observe(observation(true, at: 9.9), at: 10)
        cache.beginPause(at: 10.1)
        XCTAssertFalse(cache.acceptPauseReply(ok: false, paused: false, observation: nil,
                                              client: "safari", requestedAt: 10.1, now: 10.3))
        XCTAssertFalse(cache.observe(observation(true, at: 10), at: 10.4))
        XCTAssertNil(cache.current(at: 10.4))
        let fresh = observation(true, at: 10.5)
        XCTAssertTrue(cache.observe(fresh, at: 10.6))
        XCTAssertEqual(cache.current(at: 10.6), fresh)
    }

    func testNewerResumeOrClientChangeWinsBeforeAndAfterPauseReply() {
        for newer in [observation(true, at: 10.5),
                      observation(true, client: "music", at: 10.5),
                      observation(false, client: "music", at: 10.5)] {
            for arrivesBeforeReply in [true, false] {
                var cache = PlaybackObservationCache()
                cache.beginPause(at: 10)
                if arrivesBeforeReply { cache.observe(newer, at: 10.6) }
                XCTAssertTrue(cache.acceptPauseReply(ok: true, paused: true,
                                                     observation: observation(false, at: 10.4),
                                                     client: "safari", requestedAt: 10, now: 10.7))
                if !arrivesBeforeReply { cache.observe(newer, at: 10.8) }
                XCTAssertEqual(cache.current(at: 10.8), newer)
            }
        }
    }

    func testFailedUnsupportedAndUnverifiedRepliesCannotManufactureStoppedState() {
        let stopped = observation(false, at: 10.3)
        let replies: [(ok: Bool, paused: Bool?, observation: PlaybackObservation?)] = [
            (false, true, stopped), // A failure cannot carry a usable confirmation.
            (true, true, nil), // Legacy/unsupported observer with only a Boolean.
            (true, nil, stopped),
            (true, true, observation(true, at: 10.3)),
            (true, true, observation(false, client: "music", at: 10.3)),
            (true, true, observation(false, at: 9.9)), // Before command submission.
            (true, true, observation(false, at: 10.6)), // Future timestamp.
            (true, true, observation(false, at: .nan)),
            (true, true, observation(false, at: .infinity))
        ]
        for reply in replies {
            var cache = PlaybackObservationCache()
            cache.beginPause(at: 10)
            let fresh = observation(true, at: 10.2)
            cache.observe(fresh, at: 10.4)
            XCTAssertFalse(cache.acceptPauseReply(ok: reply.ok, paused: reply.paused, observation: reply.observation,
                                                  client: "safari", requestedAt: 10, now: 10.5))
            XCTAssertEqual(cache.current(at: 10.5), fresh)
        }
    }

    func testAlreadyStoppedReplyStillRequiresAndAppliesVerifiedObservation() {
        var cache = PlaybackObservationCache()
        cache.beginPause(at: 10)
        let stopped = observation(false, at: 10.2)
        XCTAssertTrue(cache.acceptPauseReply(ok: true, paused: false, observation: stopped,
                                             client: "safari", requestedAt: 10, now: 10.3))
        XCTAssertEqual(cache.current(at: 10.3), stopped)
    }

    func testCacheFreshnessUsesObservationTimeRatherThanDeliveryTime() {
        var cache = PlaybackObservationCache()
        let reading = observation(true, at: 10)
        XCTAssertTrue(cache.observe(reading, at: 11.9))
        XCTAssertEqual(cache.current(at: 11.99), reading)
        XCTAssertNil(cache.current(at: 12))
        XCTAssertFalse(cache.observe(observation(false, at: 10), at: 12))
        XCTAssertFalse(cache.observe(observation(false, at: 13), at: 12))
        XCTAssertFalse(cache.acceptPauseReply(ok: true, paused: true, observation: observation(false, at: 10),
                                              client: "safari", requestedAt: 9, now: 12))
    }

    func testNativeStopCannotFallBackToOlderInterpretedPlayingOrClient() {
        for client in ["safari", "music"] {
            var state = PlaybackIntentState()
            state.sample(native: reading(true, at: 10), interpreted: nil, at: 10)
            state.sample(native: reading(false, at: 10.5), interpreted: nil, at: 10.6)
            let revision = state.current(at: 10.6).revision

            state.sample(native: .unknown, interpreted: reading(true, client: client, revision: 99, at: 10.4), at: 10.7)
            let intent = state.current(at: 10.7)
            XCTAssertEqual(intent.isPlaying, false)
            XCTAssertEqual(intent.clientID, "safari")
            XCTAssertEqual(intent.observedAt, 10.5)
            XCTAssertEqual(intent.revision, revision, "A source switch must not manufacture a resume/client edge")
        }
    }

    func testOlderNativeReadCannotReplaceNewerInterpretedState() {
        for playing in [false, true] {
            var state = PlaybackIntentState()
            state.sample(native: .unknown, interpreted: reading(playing, revision: 7, at: 10.5), at: 10.6)
            let revision = state.current(at: 10.6).revision
            state.sample(native: reading(!playing, client: "music", at: 10.4), interpreted: nil, at: 10.7)
            XCTAssertEqual(state.current(at: 10.7).isPlaying, playing)
            XCTAssertEqual(state.current(at: 10.7).clientID, "safari")
            XCTAssertEqual(state.current(at: 10.7).revision, revision)
        }
    }

    func testSampleSelectsNewestExplicitSourceBeforeApplyingHistory() {
        var state = PlaybackIntentState()
        state.sample(native: reading(true, at: 10), interpreted: nil, at: 10)
        let revision = state.current(at: 10).revision
        state.sample(native: reading(false, at: 10.2),
                     interpreted: reading(true, revision: 50, at: 10.3), at: 10.4)
        XCTAssertEqual(state.current(at: 10.4).isPlaying, true)
        XCTAssertEqual(state.current(at: 10.4).revision, revision, "Do not replay both candidates as historical edges")
        state.sample(native: reading(true, at: 10.5),
                     interpreted: reading(false, revision: 50, at: 10.6), at: 10.7)
        XCTAssertEqual(state.current(at: 10.7).isPlaying, false, "Valid native data must not conceal a newer interpreted pause")
        XCTAssertEqual(state.current(at: 10.7).observedAt, 10.6)
    }

    func testNewerResumeAndClientChangesSurviveEitherSourceSwitch() {
        let sourcePairs: [(PlaybackObservationSource, PlaybackObservationSource)] = [(.native, .interpreted), (.interpreted, .native)]
        for sources in sourcePairs {
            for client in ["safari", "music"] {
                var state = PlaybackIntentState()
                state.observe(reading(false, revision: 7, at: 10), source: sources.0, at: 10)
                let revision = state.current(at: 10).revision
                state.observe(reading(true, client: client, revision: 99, at: 10.5), source: sources.1, at: 10.6)
                XCTAssertEqual(state.current(at: 10.6).isPlaying, true)
                XCTAssertEqual(state.current(at: 10.6).clientID, client)
                XCTAssertEqual(state.current(at: 10.6).revision, revision + 1)
            }
        }
    }

    func testRemoteRevisionOnlyComparesConsecutiveObservationsFromSameSource() {
        var state = PlaybackIntentState()
        state.observe(reading(true, revision: 7, at: 10), source: .interpreted, at: 10)
        let revision = state.current(at: 10).revision
        state.observe(reading(true, revision: 100, at: 10.1), source: .native, at: 10.1)
        state.observe(reading(true, revision: 8, at: 10.2), source: .interpreted, at: 10.2)
        XCTAssertEqual(state.current(at: 10.2).revision, revision)
        state.observe(reading(true, revision: 9, at: 10.3), source: .interpreted, at: 10.3)
        XCTAssertEqual(state.current(at: 10.3).revision, revision + 1, "Keep real interpreted resume-between-polls detection")
    }

    func testVerifiedPauseOrdersNativeAndInterpretedSamplesTogether() {
        var state = PlaybackIntentState()
        state.observe(reading(true, at: 10), source: .native, at: 10)
        let revision = state.current(at: 10).revision
        state.beginPause(at: 10.1)
        XCTAssertNil(state.current(at: 10.1).isPlaying)
        XCTAssertFalse(state.observe(reading(true, at: 10.05), source: .native, at: 10.2))
        XCTAssertTrue(state.acceptPause(observation(false, at: 10.4), client: "safari", requestedAt: 10.1,
                                        source: .interpreted, at: 10.5))
        state.sample(native: reading(true, at: 10.3),
                     interpreted: reading(true, revision: 99, at: 10.2), at: 10.6)
        XCTAssertEqual(state.current(at: 10.6).isPlaying, false)
        XCTAssertEqual(state.current(at: 10.6).observedAt, 10.4)
        XCTAssertEqual(state.current(at: 10.6).revision, revision)
        state.sample(native: reading(true, at: 10.7), interpreted: nil, at: 10.8)
        XCTAssertEqual(state.current(at: 10.8).isPlaying, true)
        XCTAssertEqual(state.current(at: 10.8).revision, revision + 1)
    }

    func testGlobalPauseConfirmationPreservesNewerResumeOrDifferentClient() {
        for newer in [reading(true, at: 10.5), reading(true, client: "music", at: 10.5),
                      reading(false, client: "music", at: 10.5)] {
            for arrivesBeforeReply in [true, false] {
                var state = PlaybackIntentState()
                state.observe(reading(true, at: 10), source: .interpreted, at: 10)
                state.beginPause(at: 10.1)
                if arrivesBeforeReply { state.observe(newer, source: .native, at: 10.6) }
                XCTAssertTrue(state.acceptPause(observation(false, at: 10.4), client: "safari", requestedAt: 10.1,
                                                source: .interpreted, at: 10.7))
                if !arrivesBeforeReply { state.observe(newer, source: .native, at: 10.8) }
                let revision = state.current(at: 10.8).revision
                XCTAssertEqual(state.current(at: 10.8).isPlaying, newer.playing)
                XCTAssertEqual(state.current(at: 10.8).clientID, newer.client)
                XCTAssertEqual(state.current(at: 10.8).observedAt, 10.5)
                state.sample(native: reading(true, client: "other", at: 10.3), interpreted: nil, at: 10.9)
                XCTAssertEqual(state.current(at: 10.9).revision, revision)
            }
        }
    }

    func testUnknownsUseTimestampsWithoutCreatingHistoryOrMaskingNewerPlayback() {
        var state = PlaybackIntentState()
        state.observe(reading(false, at: 10), source: .native, at: 10)
        let revision = state.current(at: 10).revision
        XCTAssertFalse(state.observe(.unknown, source: .interpreted, at: 10.1))
        XCTAssertTrue(state.observe(PlaybackReading(observedAt: 10.2), source: .native, at: 10.3))
        XCTAssertNil(state.current(at: 10.3).isPlaying)
        XCTAssertNil(state.current(at: 10.3).clientID)
        XCTAssertEqual(state.current(at: 10.3).revision, revision)
        XCTAssertFalse(state.observe(reading(true, at: 10.1), source: .interpreted, at: 10.4))
        XCTAssertTrue(state.observe(reading(true, at: 10.5), source: .interpreted, at: 10.6))
        XCTAssertFalse(state.observe(PlaybackReading(observedAt: 10.4), source: .native, at: 10.7))
        for timestamp in [10.5, 11, .nan, .infinity] {
            XCTAssertFalse(state.observe(PlaybackReading(observedAt: timestamp), source: .native, at: 10.8))
        }
        XCTAssertEqual(state.current(at: 10.8).isPlaying, true)
        XCTAssertEqual(state.current(at: 10.8).observedAt, 10.5)
        XCTAssertEqual(state.current(at: 10.8).revision, revision + 1)
    }

    func testUnknownNativeReadStillAllowsFreshInterpretedFallback() {
        var state = PlaybackIntentState()
        state.sample(native: PlaybackReading(observedAt: 10.5),
                     interpreted: reading(true, revision: 7, at: 10.4), at: 10.6)
        XCTAssertEqual(state.current(at: 10.6).isPlaying, true)
        XCTAssertEqual(state.current(at: 10.6).observedAt, 10.4)
    }

    func testGlobalExpirationRetainsWatermarkWithoutRefreshingOrCreatingEdges() {
        var state = PlaybackIntentState()
        state.sample(native: reading(false, at: 10), interpreted: nil, at: 10)
        let revision = state.current(at: 10).revision
        XCTAssertEqual(state.current(at: 11.99).isPlaying, false)
        state.sample(native: .unknown, interpreted: reading(true, at: 9.9), at: 11.99)
        XCTAssertEqual(state.current(at: 11.99).isPlaying, false)
        XCTAssertNil(state.current(at: 12).isPlaying)
        XCTAssertNil(state.current(at: 12).observedAt)
        state.sample(native: reading(true, at: 10), interpreted: nil, at: 12)
        XCTAssertNil(state.current(at: 12).isPlaying)
        XCTAssertEqual(state.current(at: 12).revision, revision)
        state.sample(native: reading(true, at: 12.1), interpreted: nil, at: 12.2)
        XCTAssertEqual(state.current(at: 12.2).isPlaying, true)
        XCTAssertEqual(state.current(at: 12.2).revision, revision + 1)
    }

    private func reading(_ playing: Bool, client: String = "safari", revision: UInt64? = nil,
                         at uptime: TimeInterval) -> PlaybackReading {
        PlaybackReading(playing: playing, client: client, observedRevision: revision, observedAt: uptime)
    }

    private func observation(_ playing: Bool, client: String = "safari", at uptime: TimeInterval) -> PlaybackObservation {
        PlaybackObservation(playing: playing, client: client, uptime: uptime, revision: 7)
    }
}

// These tests instantiate only pure policy, injected monitors and an in-memory
// command channel. No default monitor, subprocess, MediaRemote or audio API runs.
@MainActor
extension MacPlaybackIntentTests {
    func testStartupHALPlayingThenFirstKnownPlayingEstablishesBaseline() {
        var state = PlaybackIntentState()
        // HAL can be playing while MediaRemote is still unknown; it supplies no
        // ordered player observation and must not seed an invented history edge.
        XCTAssertNil(state.current(at: 10).isPlaying)
        XCTAssertEqual(state.current(at: 10).revision, 0)
        state.observe(PlaybackReading(observedAt: 10), source: .native, at: 10)
        state.observe(reading(true, revision: 5, at: 10.1), source: .interpreted, at: 10.2)
        XCTAssertEqual(state.current(at: 10.2).isPlaying, true)
        XCTAssertEqual(state.current(at: 10.2).revision, 0)
        state.observe(reading(true, revision: 6, at: 10.3), source: .interpreted, at: 10.4)
        XCTAssertEqual(state.current(at: 10.4).revision, 1, "A later proven source resume still counts")
        state.observe(reading(true, revision: 0, at: 10.5), source: .interpreted, at: 10.6)
        XCTAssertEqual(state.current(at: 10.6).revision, 1, "A restarted source counter is not proof of resume")
    }

    func testLatePauseProofDoesNotDoubleCountProvenSourceResume() {
        var state = PlaybackIntentState()
        state.observe(reading(true, revision: 5, at: 10), source: .interpreted, at: 10)
        state.beginPause(at: 10.1)
        state.observe(reading(true, revision: 6, at: 10.5), source: .interpreted, at: 10.6)
        XCTAssertEqual(state.current(at: 10.6).revision, 1)
        XCTAssertTrue(state.acceptPause(observation(false, at: 10.4), client: "safari", requestedAt: 10.1,
                                        source: .native, at: 10.6))
        XCTAssertEqual(state.current(at: 10.6).revision, 1)
        XCTAssertEqual(state.current(at: 10.6).observedAt, 10.5)
        XCTAssertEqual(state.current(at: 10.6).isPlaying, true)
    }

    func testCancellationDuringChildPauseThenCleanupJoinsOneMonitorTransaction() async throws {
        let clock = PlaybackTestClock()
        let channel = PlaybackPauseControlChannel(now: { clock.now }, sleep: { try await clock.sleep($0) })
        var ids: [String] = []
        var pauseCalls = 0
        var invalidations = 0
        let monitor = MacPlaybackIntentMonitor(read: {
            PlaybackReading(playing: true, client: "safari", observedAt: clock.now)
        }, pause: { client in
            pauseCalls += 1
            return try await channel.request(client: client, write: { ids.append(try Self.controlID($0)) },
                                             invalidate: { invalidations += 1 })
        }, now: { clock.now }, sleep: { try await clock.sleep($0) })
        let caller = Task { try await monitor.pauseForHandoff() }
        await waitUntil { channel.pendingCount == 1 }
        caller.cancel()
        await assertCanceled(caller)
        XCTAssertEqual(channel.pendingCount, 1, "Caller cancellation does not abandon child control ownership")
        let cleanup = Task { try await monitor.pauseForHandoff() }
        await drain()
        XCTAssertEqual(pauseCalls, 1)
        XCTAssertEqual(ids.count, 1, "Cleanup must not send a competing child command")
        guard let id = ids.first else { return }
        clock.advance(by: 0.4)
        channel.consume(Self.pauseReply(id, uptime: 10.3))
        let paused = try await cleanup.value
        XCTAssertTrue(paused)
        XCTAssertEqual(invalidations, 0)
        XCTAssertEqual(channel.pendingCount, 0)
    }

    func testCleanupConsumesCompletedCanceledTransactionWithoutPausingNewPlayer() async throws {
        let clock = PlaybackTestClock()
        let channel = PlaybackPauseControlChannel(now: { clock.now }, sleep: { try await clock.sleep($0) })
        var current = reading(true, at: 10)
        var ids: [String] = []
        let monitor = MacPlaybackIntentMonitor(read: { current }, pause: { client in
            try await channel.request(client: client, write: { ids.append(try Self.controlID($0)) }, invalidate: {})
        }, now: { clock.now }, sleep: { try await clock.sleep($0) })
        let caller = Task { try await monitor.pauseForHandoff() }
        await waitUntil { channel.pendingCount == 1 }
        caller.cancel()
        await assertCanceled(caller)
        guard let id = ids.first else { return }
        clock.advance(to: 10.4)
        channel.consume(Self.pauseReply(id, uptime: 10.3))
        await drain() // The unobserved owner finishes before cleanup is scheduled.
        current = reading(true, client: "music", at: 10.4)
        let newer = await monitor.sample()
        XCTAssertEqual(newer.clientID, "music")
        let cleanup = try await monitor.pauseForHandoff()
        XCTAssertTrue(cleanup)
        XCTAssertEqual(ids.count, 1, "Cleanup consumes the old receipt rather than pausing the new client")
        let after = await monitor.sample()
        XCTAssertEqual(after.clientID, "music")
        XCTAssertEqual(after.isPlaying, true)
    }

    func testBusyOwnerSurvivesNoWaitersAndRejectsDifferentClient() async throws {
        let owner = PlaybackPauseCoordinator<Int>()
        let gate = PlaybackTestGate<Int>()
        var commands = 0
        let caller = Task { try await owner.perform(client: "safari") { commands += 1; return await gate.value() } }
        await waitUntil { gate.isWaiting }
        caller.cancel()
        await assertCanceled(caller)
        XCTAssertTrue(owner.isBusy)
        XCTAssertEqual(owner.waiterCount, 0)
        do {
            _ = try await owner.perform(client: "music") { commands += 1; return 2 }
            XCTFail("A newer different player must not be paused by an existing transaction")
        } catch { XCTAssertTrue(error is PlaybackControlError) }
        let cleanup = Task { try await owner.perform(client: "safari") { commands += 1; return 3 } }
        await waitUntil { owner.waiterCount == 1 }
        gate.resolve(1)
        let value = try await cleanup.value
        XCTAssertEqual(value, 1)
        XCTAssertEqual(commands, 1)
        XCTAssertFalse(owner.isBusy)
    }

    func testCancellationFenceWinsWhenOwnerCompletesAtSameTime() async {
        let owner = PlaybackPauseCoordinator<Int>()
        let gate = PlaybackTestGate<Int>()
        let caller = Task { try await owner.perform { await gate.value() } }
        await waitUntil { gate.isWaiting }
        gate.resolve(1)
        caller.cancel() // Owner completion and cancellation are both ready to run.
        await assertCanceled(caller)
        await waitUntil { !owner.isBusy }
    }

    func testNativeWholeDeadlineDoesNotWaitForNonCooperativeVerificationRead() async {
        let clock = PlaybackTestClock()
        let gate = PlaybackTestGate<PlaybackReading>()
        var reads = 0
        var sends = 0
        let operation = Task {
            try await PlaybackPauseVerification.run(client: "safari", now: { clock.now }, read: {
                reads += 1
                if reads == 1 { return self.reading(true, at: clock.now) }
                return await gate.value() // Deliberately ignores task cancellation.
            }, sendPause: { _ in sends += 1; return true }, sleep: { try await clock.sleep($0) })
        }
        await waitUntil { clock.hasSleep(endingAt: 12.8) && sends == 1 }
        clock.advance(by: 0.15)
        await waitUntil { gate.isWaiting }
        clock.advance(to: 12.8)
        await assertFailed(operation)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(sends, 1)
        XCTAssertLessThan(PlaybackPauseBudget.native, PlaybackPauseBudget.reply)
        XCTAssertLessThan(PlaybackPauseBudget.reply, PlaybackPauseBudget.monitor)
        XCTAssertLessThan(PlaybackPauseBudget.monitor, 4)
        gate.resolve(reading(false, at: 12.7))
        await drain()
        XCTAssertEqual(sends, 1, "Late getter completion cannot reissue commands")
    }

    func testDeadlineDuringInitialReadFencesLatePauseCommand() async {
        let clock = PlaybackTestClock()
        let gate = PlaybackTestGate<PlaybackReading>()
        var sends = 0
        let operation = Task {
            try await PlaybackPauseVerification.run(client: "safari", now: { clock.now }, read: {
                await gate.value()
            }, sendPause: { _ in sends += 1; return true }, sleep: { try await clock.sleep($0) })
        }
        await waitUntil { gate.isWaiting && clock.hasSleep(endingAt: 12.8) }
        clock.advance(to: 12.8)
        await assertFailed(operation)
        gate.resolve(reading(true, at: 12.8))
        await drain()
        XCTAssertEqual(sends, 0)
    }

    func testNativeVerificationRequiresKnownClientAndAcceptedExplicitCommand() async {
        for before in [PlaybackReading.unknown, reading(true, client: "music", at: 10)] {
            let clock = PlaybackTestClock()
            var sends = 0
            let operation = Task {
                try await PlaybackPauseVerification.run(client: "safari", now: { clock.now }, read: { before },
                    sendPause: { _ in sends += 1; return true }, sleep: { try await clock.sleep($0) })
            }
            await assertFailed(operation)
            XCTAssertEqual(sends, 0)
        }
        let clock = PlaybackTestClock()
        var reads = 0
        let rejected = Task {
            try await PlaybackPauseVerification.run(client: "safari", now: { clock.now }, read: {
                reads += 1; return self.reading(true, at: clock.now)
            }, sendPause: { _ in false }, sleep: { try await clock.sleep($0) })
        }
        await assertFailed(rejected)
        XCTAssertEqual(reads, 1, "Rejected command cannot manufacture post-pause confirmation")
    }

    func testNativeAlreadyStoppedStillReturnsFreshClientObservationWithoutCommand() async throws {
        let clock = PlaybackTestClock()
        var sends = 0
        let result = try await PlaybackPauseVerification.run(client: "safari", now: { clock.now }, read: {
            self.reading(false, at: clock.now)
        }, sendPause: { _ in sends += 1; return true }, sleep: { try await clock.sleep($0) })
        XCTAssertFalse(result.paused)
        XCTAssertEqual(result.observation.client, "safari")
        XCTAssertFalse(result.observation.playing)
        XCTAssertEqual(result.observation.uptime, clock.now)
        XCTAssertEqual(sends, 0)
    }

    func testNativeUnknownAfterPauseNeedsFreshStoppedObservation() async throws {
        let clock = PlaybackTestClock()
        var reads = 0
        var sends = 0
        var completed = false
        let operation = Task {
            let result = try await PlaybackPauseVerification.run(client: "safari", now: { clock.now }, read: {
                reads += 1
                if reads == 2 { return PlaybackReading(observedAt: clock.now) }
                return self.reading(reads == 1, at: clock.now)
            }, sendPause: { _ in sends += 1; return true }, sleep: { try await clock.sleep($0) })
            completed = true
            return result
        }
        await waitUntil { sends == 1 && clock.hasSleep(endingAt: 10.15) }
        clock.advance(by: 0.15)
        await waitUntil { reads == 2 && clock.hasSleep(endingAt: 10.3) }
        XCTAssertFalse(completed, "Unknown is not confirmed stopped")
        clock.advance(by: 0.15)
        let result = try await operation.value
        XCTAssertTrue(result.paused)
        XCTAssertFalse(result.observation.playing)
        XCTAssertEqual(sends, 1)
    }

    func testClientChangeDuringNativeVerificationFailsWithoutPausingNewClient() async {
        let clock = PlaybackTestClock()
        var reads = 0
        var sends = 0
        let operation = Task {
            try await PlaybackPauseVerification.run(client: "safari", now: { clock.now }, read: {
                reads += 1
                return self.reading(true, client: reads == 1 ? "safari" : "music", at: clock.now)
            }, sendPause: { _ in sends += 1; return true }, sleep: { try await clock.sleep($0) })
        }
        await waitUntil { sends == 1 && clock.hasSleep(endingAt: 10.15) }
        clock.advance(by: 0.15)
        await assertFailed(operation)
        XCTAssertEqual(sends, 1)
    }

    func testMonitorPauseReplyPreservesNewerResumeOrClientAcrossConcurrentSamples() async throws {
        for client in ["safari", "music"] {
            let clock = PlaybackTestClock()
            let gate = PlaybackTestGate<PlaybackPauseResult>()
            var current = reading(true, at: 10)
            var sends = 0
            let monitor = MacPlaybackIntentMonitor(read: { current }, pause: { _ in
                sends += 1; return await gate.value()
            }, now: { clock.now }, sleep: { try await clock.sleep($0) })
            let pause = Task { try await monitor.pauseForHandoff() }
            await waitUntil { gate.isWaiting }
            clock.advance(to: 10.6)
            current = reading(true, client: client, at: 10.5)
            let newer = await monitor.sample()
            let joining = Task { try await monitor.pauseForHandoff() }
            await drain()
            gate.resolve((true, observation(false, at: 10.4)))
            let first = try await pause.value
            let second = try await joining.value
            XCTAssertTrue(first && second)
            let after = await monitor.sample()
            XCTAssertEqual(after.clientID, client)
            XCTAssertEqual(after.isPlaying, true)
            XCTAssertEqual(after.observedAt, 10.5)
            XCTAssertEqual(after.revision, client == "safari" ? newer.revision + 1 : newer.revision,
                           "A late verified stop proves a newer resume without counting a client edge twice")
            XCTAssertEqual(sends, 1, "Joining must not pause a newer resume or different client")
        }
    }

    func testMonitorUnknownFailsInsteadOfClaimingAlreadyPaused() async {
        let clock = PlaybackTestClock()
        var sends = 0
        let monitor = MacPlaybackIntentMonitor(read: { .unknown }, pause: { _ in
            sends += 1; return (true, self.observation(false, at: clock.now))
        }, now: { clock.now }, sleep: { try await clock.sleep($0) })
        await assertFailed(Task { try await monitor.pauseForHandoff() })
        XCTAssertEqual(sends, 0)
    }
    func testLocallyVerifiedClientCannotPauseAnotherNowPlayingClient() async {
        let clock = PlaybackTestClock()
        var sends = 0
        let monitor = MacPlaybackIntentMonitor(read: { self.reading(true, client: "spotify", at: clock.now) }, pause: { _ in
            sends += 1; return (true, self.observation(false, client: "spotify", at: clock.now))
        }, now: { clock.now }, sleep: { try await clock.sleep($0) })
        await assertFailed(Task { try await monitor.pauseForHandoff(expectedClient: "safari") })
        XCTAssertEqual(sends, 0)
    }

    func testMonitorWholeDeadlineIncludesInitialSamplingAndFencesLateCompletion() async {
        let clock = PlaybackTestClock()
        let gate = PlaybackTestGate<PlaybackReading>()
        var sends = 0
        let monitor = MacPlaybackIntentMonitor(read: { await gate.value() }, pause: { _ in
            sends += 1; return (true, self.observation(false, at: clock.now))
        }, now: { clock.now }, sleep: { try await clock.sleep($0) })
        let operation = Task { try await monitor.pauseForHandoff() }
        await waitUntil { gate.isWaiting && clock.hasSleep(endingAt: 13.8) }
        clock.advance(to: 13.8)
        await assertFailed(operation)
        gate.resolve(reading(true, at: 13.8))
        await drain()
        XCTAssertEqual(sends, 0)
    }

    func testFailedControlAndProcessExitReleasePendingControlsForNextPause() async throws {
        for exits in [false, true] {
            let clock = PlaybackTestClock()
            let channel = PlaybackPauseControlChannel(now: { clock.now }, sleep: { try await clock.sleep($0) })
            let owner = PlaybackPauseCoordinator<PlaybackPauseResult>()
            var ids: [String] = []
            var confirmations = 0
            channel.onVerifiedPause = { _, _ in confirmations += 1 }
            let request: @MainActor () async throws -> PlaybackPauseResult = {
                try await owner.perform(client: "safari") {
                    try await channel.request(client: "safari", write: { ids.append(try Self.controlID($0)) }, invalidate: {})
                }
            }
            let first = Task { try await request() }
            await waitUntil { channel.pendingCount == 1 }
            guard let id = ids.first else { return }
            if exits { channel.failAll() } // The reader invokes this on process exit and EOF.
            else {
                var reply = Self.pauseReply(id, uptime: 10)
                reply["ok"] = false
                channel.consume(reply)
            }
            await assertFailed(first)
            XCTAssertEqual(channel.pendingCount, 0)
            XCTAssertFalse(owner.isBusy)
            XCTAssertEqual(confirmations, 0)
            XCTAssertNil(channel.cachedReading())
            let next = Task { try await request() }
            await waitUntil { ids.count == 2 && channel.pendingCount == 1 }
            guard let nextID = ids.last else { return }
            channel.consume(Self.pauseReply(id, uptime: 10)) // Stale old control is ignored.
            XCTAssertEqual(channel.pendingCount, 1)
            channel.consume(Self.pauseReply(nextID, uptime: 10))
            _ = try await next.value
            XCTAssertEqual(confirmations, 1)
        }
    }

    func testChannelTimeoutRetiresTransportBeforeNextControlAndDropsLateReply() async throws {
        let clock = PlaybackTestClock()
        let channel = PlaybackPauseControlChannel(now: { clock.now }, sleep: { try await clock.sleep($0) })
        var ids: [String] = []
        var retired = false
        let request: @MainActor () async throws -> PlaybackPauseResult = {
            try await channel.request(client: "safari", write: { ids.append(try Self.controlID($0)) }, invalidate: { retired = true })
        }
        let first = Task { try await request() }
        await waitUntil { channel.pendingCount == 1 && clock.hasSleep(endingAt: 13.5) }
        clock.advance(to: 13.5)
        await assertFailed(first)
        XCTAssertTrue(retired)
        XCTAssertEqual(channel.pendingCount, 0)
        guard let oldID = ids.first else { return }
        let next = Task { try await request() }
        await waitUntil { ids.count == 2 && channel.pendingCount == 1 }
        channel.consume(Self.pauseReply(oldID, uptime: 13.5))
        XCTAssertEqual(channel.pendingCount, 1)
        guard let nextID = ids.last else { return }
        channel.consume(Self.pauseReply(nextID, uptime: 13.5))
        _ = try await next.value
    }

    func testChannelWriteFailureAndCancellationRetireUnacknowledgedChildCommand() async {
        let clock = PlaybackTestClock()
        let channel = PlaybackPauseControlChannel(now: { clock.now }, sleep: { try await clock.sleep($0) })
        var invalidations = 0
        let failed = Task {
            try await channel.request(client: "safari", write: { _ in throw PlaybackControlError(message: "fake write failed") },
                                      invalidate: { invalidations += 1 })
        }
        await assertFailed(failed)
        XCTAssertEqual(channel.pendingCount, 0)
        XCTAssertEqual(invalidations, 1)
        let canceled = Task {
            try await channel.request(client: "safari", write: { _ in }, invalidate: { invalidations += 1 })
        }
        await waitUntil { channel.pendingCount == 1 }
        canceled.cancel()
        await assertCanceled(canceled)
        await waitUntil { channel.pendingCount == 0 }
        XCTAssertEqual(invalidations, 2)
    }

    private static func controlID(_ data: Data) throws -> String {
        let row = try JSONSerialization.jsonObject(with: data) as? [String: String]
        return try XCTUnwrap(row?["id"])
    }
    private static func pauseReply(_ id: String, uptime: TimeInterval) -> [String: Any] {
        ["control": id, "ok": true, "paused": true, "playing": false, "client": "safari", "uptime": uptime]
    }
    private func drain() async { for _ in 0..<50 { await Task.yield() } }
    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Fake operation did not reach the expected suspension", file: file, line: line)
    }
    private func assertFailed<Value>(_ task: Task<Value, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        switch await task.result {
        case .success: XCTFail("Expected failure", file: file, line: line)
        case .failure: break
        }
    }
    private func assertCanceled<Value>(_ task: Task<Value, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        switch await task.result {
        case .success: XCTFail("Canceled caller returned success", file: file, line: line)
        case .failure(let error): XCTAssertTrue(error is CancellationError, file: file, line: line)
        }
    }
}

@MainActor private final class PlaybackTestGate<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    var isWaiting: Bool { continuation != nil }
    func value() async -> Value { await withCheckedContinuation { continuation = $0 } }
    func resolve(_ value: Value) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}

@MainActor private final class PlaybackTestClock {
    private(set) var now: TimeInterval = 10
    private var waits: [UUID: (deadline: TimeInterval, continuation: CheckedContinuation<Void, Error>)] = [:]
    func sleep(_ duration: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waits[id] = (now + duration, continuation)
            }
        } onCancel: {
            Task { @MainActor in self.waits.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
        }
        try Task.checkCancellation()
    }
    func hasSleep(endingAt deadline: TimeInterval) -> Bool {
        waits.values.contains { abs($0.deadline - deadline) < 0.000_001 }
    }
    func advance(by duration: TimeInterval) { advance(to: now + duration) }
    func advance(to uptime: TimeInterval) {
        precondition(uptime >= now)
        now = uptime
        let due = waits.filter { $0.value.deadline <= now + 0.000_001 }.map(\.key)
        for id in due { waits.removeValue(forKey: id)?.continuation.resume() }
    }
}
