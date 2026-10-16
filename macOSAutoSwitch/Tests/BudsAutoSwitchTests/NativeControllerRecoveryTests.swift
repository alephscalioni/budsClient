import XCTest
@testable import BudsAutoSwitch

/// Manual clock and effects: no Bluetooth, HAL, applications, journal or network.
@MainActor final class NativeControllerHarness {
    var time: TimeInterval = 0
    var frame: ((SamsungMdePacket.Frame) -> Void)?
    var failure: ((NativeBudsError) -> Void)?
    var open = false
    var armed = false
    var arms = 0
    var output: UInt32 = 1
    var targetAvailable = true
    var selectedBudsRoutes: Set<UInt32> = [2]
    var playing = false
    var otherOutput = false
    var sampleIsUnknown = false
    var localOutputUnavailable = false
    var inputActive = false
    var pendingOperations = 0
    var revision: UInt64 = 0
    var opens = 0
    var pauses = 0
    var restores = 0
    var commands: [Data] = []
    var hud: [String] = []
    var openFailures = 0
    var holdOpen = false
    var holdNoncooperativeOpen = false
    var openGate: CheckedContinuation<Void, Never>?
    var holdRoute = false
    var applyRouteAfterWait = false
    var routeGate: CheckedContinuation<Void, Never>?
    var routeWrites: [UInt32] = []
    var holdLink = false
    var linkGate: CheckedContinuation<Void, Never>?
    var playbackStarts = 0
    var openHook: (() -> Void)?
    var sampleHook: (() -> Void)?
    var linkError: String?
    var pauseError: String?
    var restoreError: String?
    var verifyError: String?
    var pauseGate: CheckedContinuation<Void, Never>?
    var holdPause = false
    var linked = true
    var linkHook: (() -> Void)?
    var routeHook: (() -> Void)?
    var physicalReleasePolicy = false
    var remoteReleaseSettleDelay: TimeInterval = 0
    var physicalCloses = 0
    var closeInFlight = false
    var holdClose = false
    var closeGate: CheckedContinuation<Void, Never>?
    var closeError: String?
    var closeDropsLink = true
    var bootstrapState = true
    var bootstrapCall = false
    var linkReads = 0
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]

    func environment() -> NativeSwitchEnvironment {
        var result = NativeSwitchEnvironment(now: { self.time }, sleep: { try await self.sleep($0) },
            pairedBuds: { [("AA:BB:CC:DD:EE:FF", "Test Buds")] },
            handlers: { self.frame = $0; self.failure = $1 },
            isOpen: { self.open }, open: { _ in
                XCTAssertTrue(self.armed, "Open must never start before speaker protection")
                XCTAssertFalse(self.closeInFlight, "No open may overlap an accepted physical close")
                self.opens += 1
                if self.holdOpen { try await self.sleep(100) }
                if self.holdNoncooperativeOpen {
                    await withCheckedContinuation { self.openGate = $0 }
                }
                if self.openFailures > 0 {
                    self.openFailures -= 1
                    throw NativeBudsError(message: "opening-primary")
                }
                self.open = true
                if self.physicalReleasePolicy { self.linked = true }
                self.openHook?()
            }, close: { self.open = false }, send: {
                self.commands.append($0)
                if self.physicalReleasePolicy, self.bootstrapState,
                   $0 == SamsungMdePacket.readSeamlessConnection() {
                    self.notify(.background, stream: self.bootstrapCall ? .hfp : [])
                }
            },
            isArmed: { self.armed }, armedDevice: { self.armed ? 1 : nil },
            arm: { _ in self.arms += 1; self.armed = true }, verify: {
                if let message = self.verifyError { throw NativeBudsError(message: message) }
            }, restore: {
                if self.armed { XCTAssertFalse(self.playing && !self.localOutputUnavailable, "Local output must be quiet before releasing speaker protection") }
                self.restores += 1
                if let message = self.restoreError { throw NativeBudsError(message: message) }
                self.armed = false
            }, startPlayback: { self.playbackStarts += 1 }, stopPlayback: {},
            sample: { self.sampleHook?(); return MacPlaybackIntent(isPlaying: self.sampleIsUnknown ? nil : self.playing && !self.localOutputUnavailable, clientID: self.sampleIsUnknown ? nil : "test", revision: self.revision, observedAt: self.sampleIsUnknown ? nil : self.time, reportedIsPlaying: self.sampleIsUnknown ? nil : self.playing) },
            pause: {
                self.pauses += 1
                if self.holdPause { await withCheckedContinuation { self.pauseGate = $0 } }
                if let message = self.pauseError { throw NativeBudsError(message: message) }
                self.playing = false
            }, activity: { AudioActivity(output: (self.playing && !self.localOutputUnavailable) || self.otherOutput, input: self.inputActive) }, defaultOutput: { self.output },
            output: { _ in self.targetAvailable ? 2 : nil }, waitingOutput: { _ in 1 },
            setOutput: {
                XCTAssertTrue(self.armed)
                self.routeWrites.append($0)
                // Cover both delayed application and delayed confirmation. The
                // gate intentionally does not cooperate with cancellation.
                if self.holdRoute, self.applyRouteAfterWait {
                    await withCheckedContinuation { self.routeGate = $0 }
                }
                self.output = $0
                self.routeHook?()
                if self.holdRoute, !self.applyRouteAfterWait {
                    await withCheckedContinuation { self.routeGate = $0 }
                }
            },
            linked: { _ in
                self.linkReads += 1
                if self.holdLink { await withCheckedContinuation { self.linkGate = $0 } }
                self.linkHook?()
                if let message = self.linkError { throw NativeBudsError(message: message) }
                return self.linked
            }, loadBattery: { _ in nil },
            show: { _, destination, _, _ in self.hud.append(destination) },
            diagnostics: { ["pending_operations": self.pendingOperations] },
            outputBelongsToBuds: { id, _ in self.selectedBudsRoutes.contains(id) })
        if physicalReleasePolicy {
            result.remoteReleaseSettleDelay = remoteReleaseSettleDelay
            result.releaseBluetooth = { _ in
                XCTAssertTrue(self.armed)
                XCTAssertEqual(self.output, 1)
                XCTAssertFalse(self.open, "Own SMEP must close before physical release")
                XCTAssertFalse(self.playing)
                XCTAssertNil(self.frame); XCTAssertNil(self.failure)
                self.physicalCloses += 1; self.closeInFlight = true
                defer { self.closeInFlight = false }
                if self.holdClose { await withCheckedContinuation { self.closeGate = $0 } }
                if let message = self.closeError { throw NativeBudsError(message: message) }
                if self.closeDropsLink { self.linked = false }
            }
        }
        return result
    }

    func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { sleepers[id] = (time + seconds, $0) }
        } onCancel: {
            Task { @MainActor in self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
    func settle() async { for _ in 0..<100 { await Task.yield() } }
    func advance(_ seconds: TimeInterval) async {
        time += seconds
        let due = sleepers.filter { $0.value.0 <= time }
        for (id, value) in due { sleepers.removeValue(forKey: id); value.1.resume() }
        await settle()
    }
    func start() async -> NativeAutoSwitchModel {
        let model = NativeAutoSwitchModel(environment: environment())
        await model.refresh() // fake inventory only
        model.start(transportGranted: true)
        await settle()
        return model
    }
    func play() { playing = true; revision += 1 }
    var requests: Int { commands.filter { $0 == SamsungMdePacket.requestComputerSwitch() }.count }
    func notify(_ state: SamsungMdePacket.MultipointStatus.State = .foreground,
                stream: SamsungMdePacket.StreamType = .a2dp, reason: UInt8 = 0, command: UInt8 = 0x45) {
        var value = [UInt8](repeating: 0, count: 18)
        value[0] = 0x0B; value[1] = state.rawValue; value[2] = reason; value[7] = stream.rawValue
        let prefix: [UInt8] = command == 0x44 ? [0, 2] : []
        frame?(.init(command: command, payload: Data(prefix + [0x02, 0x05, 18] + value),
                     sequence: 0, isResponse: false, isFragment: false))
    }
    func loseChannel() { open = false; failure?(NativeBudsError(message: "channel-primary")) }
    func stop(_ model: NativeAutoSwitchModel) async { model.stop(); await settle() }
    func acquire(_ model: NativeAutoSwitchModel) async {
        play(); await advance(0.2)
        notify(); await advance(0.15)
        XCTAssertEqual(model.route, "Mac")
    }
}

@MainActor private final class NativeModelWeakReference {
    weak var value: NativeAutoSwitchModel?
    init(_ value: NativeAutoSwitchModel?) { self.value = value }
}

final class NativeControllerRecoveryTests: XCTestCase {
    @MainActor func testIdleBackgroundSettingsInspectionDoesNotRequireOrRequestMacAudioOwnership() async {
        let h = NativeControllerHarness()
        let model = await h.start()
        h.notify(.background); await h.settle()
        let opens = h.opens, commands = h.commands.count, routes = h.routeWrites.count, pauses = h.pauses
        XCTAssertTrue(model.enabled)
        XCTAssertFalse(model.canManageSettings)
        XCTAssertTrue(model.canInspectSettings)
        XCTAssertEqual(h.opens, opens); XCTAssertEqual(h.commands.count, commands)
        XCTAssertEqual(h.routeWrites.count, routes); XCTAssertEqual(h.pauses, pauses)
        await h.stop(model)
    }
    @MainActor func testForeground132DuringAcquisitionAndPlaybackNeverTriggersFailureRecovery() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start()
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.requests, 1)
        h.notify(.foreground, reason: 132); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac"); XCTAssertTrue(model.enabled)
        XCTAssertNil(model.error); XCTAssertEqual(h.pauses, 0); XCTAssertEqual(h.restores, 0)
        h.notify(.foreground, reason: 133); await h.settle()
        h.notify(.foreground, reason: 132); await h.settle()
        XCTAssertTrue(model.enabled); XCTAssertEqual(model.route, "Mac")
        XCTAssertNil(model.error); XCTAssertEqual(h.pauses, 0)
        XCTAssertTrue(h.playing); XCTAssertTrue(h.open)
        await h.stop(model)
    }
    @MainActor func testOSCanSelectBudsUIDBeforeHALPublishesStreams() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.play(); await h.advance(0.2)
        h.selectedBudsRoutes.insert(20)
        h.linkHook = { h.output = 20; h.targetAvailable = false }
        h.notify(); await h.advance(0.15)
        XCTAssertTrue(model.enabled); XCTAssertTrue(h.armed); XCTAssertTrue(model.busy)
        XCTAssertTrue(h.hud.isEmpty); XCTAssertNotEqual(model.route, "Mac")
        h.targetAvailable = true; h.linkHook = nil
        await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac"); XCTAssertEqual(h.output, 2)
        XCTAssertEqual(h.hud, ["Conectado ao Mac"])
        await h.stop(model)
    }

    @MainActor func testUnknownPlayerWithHALOutputCannotAcquireDisconnectedBuds() async {
        let h = NativeControllerHarness(); h.linked = false; h.sampleIsUnknown = true
        let model = await h.start()
        h.play(); await h.advance(0.2); await h.advance(30)
        XCTAssertEqual(h.requests, 0)
        XCTAssertEqual(h.opens, 0)
        XCTAssertFalse(h.armed)
        XCTAssertTrue(model.enabled)
        h.playing = false; await h.stop(model)
    }

    @MainActor func testExpiredPlayerCannotTurnRetainedHALStreamIntoAnotherRequest() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        h.notify(.background); await h.settle()
        XCTAssertEqual(model.route, "Galaxy")
        h.sampleIsUnknown = true; h.otherOutput = true
        await h.advance(0.2); await h.advance(3); await h.advance(30)
        XCTAssertEqual(h.requests, 1, "An uncertain player and retained audio stream cannot replay the Mac's intent")
        XCTAssertEqual(h.pauses, 1, "No repeated pause may be manufactured from source uncertainty")
        h.sampleIsUnknown = false; h.otherOutput = false; await h.stop(model)
    }

    @MainActor func testInputAndOutputCannotOverrideExplicitPausedMediaForAcquisition() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.otherOutput = true; h.inputActive = true
        await h.advance(0.2); await h.advance(5)
        XCTAssertEqual(h.requests, 0, "A running call/capture is not a media play from the paused player")
        h.otherOutput = false; h.inputActive = false; await h.stop(model)
    }

    @MainActor func testUnknownReadingInvalidatesCooldownIntentWithoutCreatingAnotherEdge() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        h.notify(.background); await h.settle()
        h.play(); await h.advance(0.2)
        h.sampleIsUnknown = true; await h.advance(0.2); await h.advance(4)
        XCTAssertEqual(h.requests, 1)
        h.sampleIsUnknown = false; await h.advance(0.2)
        XCTAssertEqual(h.requests, 1, "Returning to the same reading is not a fresh pause/play")
        h.playing = false; await h.advance(0.2)
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.requests, 2)
        h.notify(); await h.advance(0.15); await h.stop(model)
    }

    @MainActor func testInterpreterWarmupCannotReinterpretAlreadyRunningHALAsFreshPlay() async {
        let h = NativeControllerHarness(); h.linked = false; h.playing = true; h.sampleIsUnknown = true
        let model = await h.start()
        h.sampleIsUnknown = false // First known client is a baseline (revision0), not a play.
        await h.advance(0.2)
        XCTAssertEqual(h.requests, 0); XCTAssertEqual(h.opens, 0)
        h.playing = false; await h.advance(0.2)
        h.openHook = { h.linked = true }
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.requests, 1)
        h.notify(); await h.advance(0.15); await h.stop(model)
    }

    @MainActor func testPlayerBecomingUnknownDuringOpenCannotSendSwitchRequest() async {
        let h = NativeControllerHarness(); h.linked = false
        let model = await h.start()
        h.openHook = { h.linked = true; h.sampleIsUnknown = true }
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.requests, 0)
        h.sampleIsUnknown = false; h.playing = false; await h.stop(model)
    }
    @MainActor func testDisconnectedBudsWaitForPlayBeforeAnyRadioRequest() async {
        let h = NativeControllerHarness(); h.linked = false
        let model = await h.start()
        XCTAssertTrue(model.enabled); XCTAssertFalse(model.busy)
        XCTAssertFalse(h.armed, "Unavailable/disconnected Buds must not mute idle Mac audio")
        XCTAssertEqual(h.opens, 0); XCTAssertTrue(h.commands.isEmpty)
        await h.advance(10); XCTAssertEqual(h.opens, 0)
        h.openHook = { h.linked = true }
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.requests, 1)
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        await h.stop(model)
    }

    @MainActor func testAlreadyPlayingWhenEnabledDoesNotConnectDisconnectedBuds() async {
        let h = NativeControllerHarness(); h.linked = false; h.playing = true
        let model = await h.start()
        await h.advance(1); XCTAssertEqual(h.opens, 0)
        h.playing = false; await h.advance(0.2)
        h.openHook = { h.linked = true }
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.opens, 1)
        await h.stop(model)
    }

    @MainActor func testUnavailableBudsCannotHoldAudioBeyondWholeAttemptDeadline() async {
        let h = NativeControllerHarness(); h.linked = false; h.holdOpen = true
        let model = await h.start()
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.opens, 1); XCTAssertTrue(model.busy)
        await h.advance(12)
        XCTAssertFalse(h.playing); XCTAssertFalse(h.armed)
        XCTAssertTrue(model.error?.contains("doze segundos") == true)
        await h.advance(1)
        await h.advance(30)
        XCTAssertFalse(h.armed, "After timeout, recovery must not leave an absent-headset mute armed")
        XCTAssertFalse(model.busy)
        XCTAssertEqual(h.opens, 1, "Time alone must not repeatedly connect unavailable Buds")
        await h.stop(model)
        XCTAssertFalse(model.busy)
    }

    @MainActor func testInitialLinkAwaitPreservesNewPlayWithoutStealingExistingPlayback() async {
        for alreadyPlaying in [false, true] {
            let h = NativeControllerHarness()
            h.linked = false; h.holdLink = true; h.playing = alreadyPlaying
            let model = await h.start()
            XCTAssertNotNil(h.linkGate); XCTAssertEqual(h.playbackStarts, 1)
            XCTAssertFalse(h.armed); XCTAssertEqual(h.opens, 0)
            if !alreadyPlaying { h.play() }
            await h.advance(5)
            h.holdLink = false; h.linkGate?.resume(); h.linkGate = nil
            await h.settle()
            XCTAssertEqual(h.opens, alreadyPlaying ? 0 : 1)
            XCTAssertEqual(h.requests, alreadyPlaying ? 0 : 1)
            XCTAssertTrue(h.hud.isEmpty)
            await h.stop(model)
        }
    }

    @MainActor func testNoncooperativeOpenRestoresBeforeDrainAndFencesLateChannel() async {
        for stopDuringDrain in [false, true] {
            let h = NativeControllerHarness(); h.linked = false; h.holdNoncooperativeOpen = true
            let model = await h.start()
            h.play(); await h.advance(0.2)
            XCTAssertNotNil(h.openGate); XCTAssertTrue(h.armed)
            // No SDK pending-operation counter: the controller must retain its
            // own lease even when diagnostics cannot see the suspended work.
            XCTAssertEqual(h.pendingOperations, 0)
            await h.advance(12)
            XCTAssertFalse(h.playing); XCTAssertFalse(h.armed); XCTAssertEqual(h.restores, 1)
            XCTAssertTrue(model.busy); XCTAssertTrue(model.transportIsSettling)
            XCTAssertTrue(model.error?.contains("doze segundos") == true)
            let pauses = h.pauses
            h.play() // A later user's audio must not be paused again just to drain.
            if stopDuringDrain { model.stop() }
            model.start(transportGranted: true)
            await model.refresh(); await h.advance(60)
            XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.arms, 1)
            XCTAssertEqual(h.pauses, pauses); XCTAssertTrue(h.playing)
            XCTAssertTrue(h.commands.isEmpty); XCTAssertTrue(h.hud.isEmpty)
            h.holdNoncooperativeOpen = false; h.openGate?.resume(); h.openGate = nil
            await h.settle()
            XCTAssertFalse(h.open, "A channel returned after cancellation must be closed before releasing the lease")
            XCTAssertFalse(model.transportIsSettling)
            XCTAssertTrue(h.commands.isEmpty); XCTAssertTrue(h.hud.isEmpty)
            await h.advance(1)
            XCTAssertEqual(h.opens, 1, "Disconnected recovery must wait for another play")
            XCTAssertEqual(model.enabled, !stopDuringDrain)
            if !stopDuringDrain {
                h.play(); await h.advance(0.2)
                XCTAssertEqual(h.opens, 2); XCTAssertEqual(h.requests, 1)
            }
            await h.stop(model)
        }
    }

    @MainActor func testNoncooperativeDrainNeverBypassesPauseSafety() async {
        for pauseFailure in [false, true] {
            let h = NativeControllerHarness(); h.linked = false; h.holdNoncooperativeOpen = true
            let model = await h.start()
            h.play(); await h.advance(0.2)
            if pauseFailure { h.pauseError = "unconfirmed-pause" }
            else { h.otherOutput = true }
            await h.advance(12)
            XCTAssertTrue(h.armed); XCTAssertEqual(h.restores, 0)
            XCTAssertTrue(model.enabled); XCTAssertTrue(model.recoveryPending)
            XCTAssertTrue(model.transportIsSettling)
            await h.advance(60); XCTAssertEqual(h.opens, 1)
            h.holdNoncooperativeOpen = false; h.openGate?.resume(); h.openGate = nil
            await h.settle()
            XCTAssertFalse(h.open); XCTAssertTrue(h.armed); XCTAssertFalse(model.busy)
            h.pauseError = nil; h.otherOutput = false
            await h.stop(model)
            XCTAssertFalse(h.armed); XCTAssertFalse(model.recoveryPending)
        }
    }

    @MainActor func testNoncooperativeRouteRestoresBeforeDrainAndCannotConfirmOldHandoff() async {
        let h = NativeControllerHarness(); let model = await h.start()
        let staleFrame = h.frame, staleFailure = h.failure
        h.play(); await h.advance(0.2)
        h.holdRoute = true; h.notify(); await h.advance(0.15)
        XCTAssertNotNil(h.routeGate); XCTAssertEqual(h.routeWrites, [2])
        await h.advance(12)
        XCTAssertFalse(h.playing); XCTAssertFalse(h.armed); XCTAssertEqual(h.restores, 1)
        XCTAssertTrue(model.transportIsSettling); XCTAssertTrue(model.busy)
        model.stop(); model.start(transportGranted: true)
        staleFailure?(NativeBudsError(message: "obsolete-failure"))
        h.output = 3 // Manual choice while the submitted write drains.
        await h.advance(60)
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.arms, 1)
        h.holdRoute = false; h.routeGate?.resume(); h.routeGate = nil
        await h.settle()
        staleFrame?(.init(command: 0x45, payload: Data(), sequence: 0, isResponse: false, isFragment: false))
        await h.advance(60)
        XCTAssertEqual(h.output, 3); XCTAssertEqual(h.routeWrites, [2])
        XCTAssertEqual(h.requests, 1); XCTAssertEqual(h.opens, 1)
        XCTAssertTrue(h.hud.isEmpty); XCTAssertNotEqual(model.route, "Mac")
        XCTAssertFalse(model.enabled); XCTAssertFalse(model.busy); XCTAssertFalse(model.transportIsSettling)
        XCTAssertFalse(model.error?.contains("obsolete-failure") == true)
        await h.stop(model)
    }

    @MainActor func testForegroundDuringWaitingRouteWriteReconcilesWithoutClaimingOwnership() async {
        for delayedApplication in [false, true] {
            let h = NativeControllerHarness(); let model = await h.start()
            await h.acquire(model)
            h.holdRoute = true; h.applyRouteAfterWait = delayedApplication
            h.notify(.background); await h.settle()
            XCTAssertNotNil(h.routeGate)
            XCTAssertEqual(h.output, delayedApplication ? 2 : 1); XCTAssertFalse(h.playing)
            h.notify(.foreground); await h.settle()
            h.holdRoute = false; h.routeGate?.resume(); h.routeGate = nil
            await h.settle(); await h.advance(3)
            XCTAssertTrue(model.enabled); XCTAssertTrue(h.armed)
            XCTAssertEqual(h.output, 1); XCTAssertNotEqual(model.route, "Mac"); XCTAssertNotEqual(model.route, "Galaxy")
            XCTAssertEqual(h.hud, ["Conectado ao Mac"]); XCTAssertEqual(h.requests, 1)
            h.notify(.background); await h.settle()
            XCTAssertEqual(model.route, "Galaxy")
            XCTAssertEqual(h.hud, ["Conectado ao Mac", "Conectado ao Galaxy"])
            await h.stop(model)
        }
    }

    @MainActor func testNewPlayDuringSupersededWaitingRouteWriteRequiresFreshAcquisition() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        h.holdRoute = true; h.notify(.background); await h.settle()
        h.notify(.foreground); h.play()
        h.holdRoute = false; h.routeGate?.resume(); h.routeGate = nil
        await h.settle(); await h.advance(3)
        XCTAssertEqual(h.output, 1); XCTAssertNotEqual(model.route, "Mac")
        XCTAssertEqual(h.requests, 2, "A new play must request/confirm again, not inherit the old foreground")
        XCTAssertEqual(h.hud, ["Conectado ao Mac"])
        h.notify(.foreground); await h.advance(0.15)
        XCTAssertEqual(h.output, 2); XCTAssertEqual(model.route, "Mac")
        XCTAssertEqual(h.hud, ["Conectado ao Mac", "Conectado ao Mac"])
        await h.stop(model)
    }

    @MainActor func testPausedReacquisitionDoesNotEraseAbortedReleaseObligation() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        h.holdPause = true; h.notify(.background); await h.settle()
        h.notify(.foreground)
        h.holdPause = false; h.pauseGate?.resume(); h.pauseGate = nil
        await h.settle()
        XCTAssertEqual(h.output, 2)
        h.linkHook = { h.playing = false }
        h.play(); await h.advance(3)
        h.linkHook = nil
        XCTAssertNotEqual(model.route, "Mac"); XCTAssertEqual(h.requests, 1)
        XCTAssertEqual(h.hud, ["Conectado ao Mac"])
        h.holdRoute = true; h.notify(.background); await h.settle()
        XCTAssertNotNil(h.routeGate, "Aborted adoption must still release the old Buds route")
        XCTAssertNotEqual(model.route, "Galaxy"); XCTAssertEqual(h.hud, ["Conectado ao Mac"])
        h.holdRoute = false; h.routeGate?.resume(); h.routeGate = nil
        await h.settle()
        XCTAssertEqual(h.output, 1); XCTAssertEqual(model.route, "Galaxy")
        XCTAssertEqual(h.hud, ["Conectado ao Mac", "Conectado ao Galaxy"])
        await h.stop(model)
    }

    @MainActor func testForegroundDuringWaitingRouteWriteRespectsManualOutputAndPause() async {
        for manualOutput in [false, true] {
            let h = NativeControllerHarness(); let model = await h.start()
            await h.acquire(model)
            h.holdRoute = true; h.notify(.background); await h.settle()
            h.notify(.foreground)
            // A play followed by a user pause must not survive as intent.
            h.play(); h.playing = false
            if manualOutput { h.output = 3 }
            h.holdRoute = false; h.routeGate?.resume(); h.routeGate = nil
            await h.settle(); await h.advance(60)
            XCTAssertEqual(h.output, manualOutput ? 3 : 1)
            XCTAssertEqual(model.enabled, !manualOutput)
            XCTAssertFalse(h.playing); XCTAssertEqual(h.requests, 1)
            XCTAssertEqual(h.routeWrites, [2, 1]); XCTAssertEqual(h.opens, 1)
            XCTAssertEqual(h.hud, ["Conectado ao Mac"])
            await h.stop(model)
        }
    }

    @MainActor func testAcceptedPlaybackDiagnosticsContainOnlyRevisionAndObservationTime() async {
        let h = NativeControllerHarness(); h.linked = false; h.playing = true
        let model = await h.start()
        func edges() -> [[String: Any]] {
            (model.transportDiagnostics["controller_events"] as? [[String: Any]] ?? [])
                .filter { $0["event"] as? String == "local_playback_edge_accepted" }
        }
        XCTAssertTrue(edges().isEmpty, "Startup playback is not an accepted edge")
        h.playing = false; await h.advance(0.2)
        h.play(); await h.advance(0.2)
        let events = edges()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?["revision"] as? UInt64, h.revision)
        XCTAssertEqual(events.first?["observed_at"] as? TimeInterval, h.time)
        XCTAssertEqual(Set(events.first?.keys.map { $0 } ?? []), Set(["event", "uptime", "revision", "observed_at"]))
        await h.advance(1)
        XCTAssertEqual(edges().count, 1, "The same playing revision cannot explain a second request")
        h.linked = true; h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        h.notify(.background); await h.settle()
        h.play(); await h.advance(0.2)
        let repeated = edges()
        XCTAssertEqual(repeated.count, 2)
        XCTAssertEqual(repeated.last?["revision"] as? UInt64, h.revision)
        XCTAssertEqual(repeated.last?["observed_at"] as? TimeInterval, h.time)
        XCTAssertEqual(Set(repeated.last?.keys.map { $0 } ?? []), Set(["event", "uptime", "revision", "observed_at"]))
        XCTAssertEqual(h.requests, 1, "A cooldown edge is recorded when accepted, before sending another request")
        await h.stop(model)
    }

    @MainActor func testRemoteRequestThenMediaConfirmsGalaxyRegardlessOfOrder() async {
        for mediaBeforePause in [false, true] {
            let h = NativeControllerHarness(); let model = await h.start()
            await h.acquire(model)
            h.holdPause = mediaBeforePause
            h.notify(.background, stream: .autoSwitchRequest); await h.settle()
            if !mediaBeforePause { XCTAssertNotEqual(model.route, "Galaxy") }
            h.notify(.background, stream: .a2dp); await h.settle()
            if mediaBeforePause {
                h.holdPause = false; h.pauseGate?.resume(); h.pauseGate = nil
                await h.settle()
            }
            XCTAssertEqual(model.route, "Galaxy")
            XCTAssertEqual(h.hud, ["Conectado ao Mac", "Conectado ao Galaxy"])
            await h.stop(model)
        }
    }

    @MainActor func testBackgroundDuringActivityReadDoesNotStartCompetingPauseOrRequest() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        var delivered = false
        h.sampleHook = {
            guard !delivered else { return }; delivered = true
            h.notify(.background, stream: .hfp)
        }
        await h.advance(0.2)
        XCTAssertEqual(h.pauses, 1)
        XCTAssertEqual(h.requests, 1)
        XCTAssertTrue(model.enabled)
        h.sampleHook = nil; await h.stop(model)
    }

    @MainActor func testSupersededRadioFailureDoesNotTearDownRemoteHandoff() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        var delivered = false
        h.linkHook = {
            guard !delivered else { return }; delivered = true
            h.notify(.background)
            h.linkError = "old-radio-read"
        }
        await h.advance(2)
        XCTAssertTrue(model.enabled)
        XCTAssertFalse(model.error?.contains("old-radio-read") == true)
        h.linkHook = nil; h.linkError = nil; await h.stop(model)
    }

    @MainActor func testRecoveryRejectsStartAndRefreshWithoutErasingPrimaryFailure() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.play(); h.pauseError = "pause-recovery"; h.loseChannel(); await h.settle()
        XCTAssertTrue(model.recoveryPending)
        model.start(transportGranted: true)
        await model.refresh()
        XCTAssertTrue(model.error?.contains("channel-primary") == true)
        XCTAssertTrue(model.error?.contains("pause-recovery") == true)
        XCTAssertEqual(model.transportDiagnostics["original_failure"] as? String, "channel-primary")
        h.pauseError = nil; await h.stop(model)
    }

    @MainActor func testRemoteOwnershipMovesAudioToProtectedWaitingOutput() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        XCTAssertEqual(h.output, 2)
        h.otherOutput = true
        h.notify(.background); await h.settle()
        XCTAssertFalse(h.playing)
        XCTAssertEqual(h.output, 1, "Do not keep the Buds as Mac's default output after yielding")
        XCTAssertTrue(h.armed, "Other applications must remain protected")
        XCTAssertEqual(model.route, "Galaxy")
        h.otherOutput = false; await h.stop(model)
    }

    @MainActor func testManualRouteDuringYieldPauseIsRespectedWithoutReconnect() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        h.holdPause = true
        h.notify(.background); await h.settle()
        h.output = 3
        h.holdPause = false; h.pauseGate?.resume(); h.pauseGate = nil
        await h.settle(); await h.advance(100)
        XCTAssertEqual(h.output, 3)
        XCTAssertFalse(model.enabled)
        XCTAssertEqual(h.opens, 1)
        XCTAssertEqual(h.hud, ["Conectado ao Mac"])
        await h.stop(model)
    }

    @MainActor func testNewForegroundSupersedesPendingYieldRoute() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        h.holdPause = true
        h.notify(.background); await h.settle()
        h.notify(.foreground); await h.settle()
        h.holdPause = false; h.pauseGate?.resume(); h.pauseGate = nil
        await h.settle()
        XCTAssertEqual(h.output, 2, "Old background work must not change a newer foreground route")
        XCTAssertEqual(h.hud, ["Conectado ao Mac"])
        XCTAssertNotEqual(model.route, "Mac", "Foreground alone cannot forge restored ownership")
        h.holdPause = true
        h.notify(.background, stream: .autoSwitchRequest); await h.settle()
        XCTAssertNotNil(h.pauseGate, "The later background must perform an actual replacement yield")
        h.notify(.background, stream: .a2dp); await h.settle()
        XCTAssertEqual(h.output, 2)
        XCTAssertNotEqual(model.route, "Galaxy"); XCTAssertEqual(h.hud, ["Conectado ao Mac"])
        h.holdPause = false; h.pauseGate?.resume(); h.pauseGate = nil
        await h.settle()
        XCTAssertEqual(h.output, 1); XCTAssertEqual(model.route, "Galaxy")
        XCTAssertEqual(h.hud, ["Conectado ao Mac", "Conectado ao Galaxy"])
        await h.stop(model)
    }

    @MainActor func testOpeningFailureRestoresAndRetriesWithoutDisablingOrLosingReady() async {
        let h = NativeControllerHarness(); h.openFailures = 1
        let model = await h.start()
        XCTAssertTrue(model.enabled); XCTAssertTrue(model.busy); XCTAssertTrue(model.ready)
        XCTAssertFalse(h.armed); XCTAssertEqual(h.restores, 1); XCTAssertEqual(h.opens, 1)
        XCTAssertTrue(model.error?.contains("opening-primary") == true)
        await h.advance(0.9); XCTAssertEqual(h.opens, 1)
        await h.advance(0.1); XCTAssertEqual(h.opens, 2)
        XCTAssertTrue(model.enabled); XCTAssertFalse(model.busy); XCTAssertTrue(h.armed)
        XCTAssertEqual(Array(h.commands.prefix(2)), [SamsungMdePacket.settingInfoClassicBluetooth(), SamsungMdePacket.configureVersion3()])
        await h.stop(model)
        XCTAssertFalse(h.armed); XCTAssertTrue(model.ready)
    }

    @MainActor func testStopDuringBackoffCannotReconnectEvenThroughOldCallbacks() async {
        let h = NativeControllerHarness(); let model = await h.start()
        let staleFrame = h.frame, staleFailure = h.failure
        h.loseChannel(); await h.settle()
        XCTAssertTrue(model.enabled); XCTAssertTrue(model.busy); XCTAssertFalse(h.armed)
        await h.stop(model)
        staleFailure?(NativeBudsError(message: "late"))
        staleFrame?(.init(command: 0x45, payload: Data(), sequence: 0, isResponse: false, isFragment: false))
        await h.advance(100)
        XCTAssertEqual(h.opens, 1); XCTAssertFalse(model.enabled); XCTAssertFalse(model.busy)
        XCTAssertFalse(h.armed); XCTAssertFalse(h.open)
    }

    @MainActor func testStopWhileRecoveryPauseIsSuspendedCannotRestart() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.play(); h.holdPause = true; h.loseChannel(); await h.settle()
        XCTAssertTrue(h.armed); XCTAssertTrue(model.enabled); XCTAssertTrue(model.busy)
        model.stop()
        h.holdPause = false; h.pauseGate?.resume(); h.pauseGate = nil
        await h.settle(); await h.advance(100)
        XCTAssertEqual(h.opens, 1); XCTAssertFalse(model.enabled); XCTAssertFalse(model.busy)
        XCTAssertFalse(h.armed)
    }

    @MainActor func testPrimaryAndPauseRecoveryErrorsWaitForAutomaticRecovery() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.play(); h.pauseError = "pause-recovery"; h.loseChannel(); await h.settle()
        XCTAssertTrue(model.enabled); XCTAssertFalse(model.busy); XCTAssertTrue(model.recoveryPending)
        XCTAssertTrue(model.error?.contains("channel-primary") == true)
        XCTAssertTrue(model.error?.contains("pause-recovery") == true)
        XCTAssertFalse(model.error?.contains("Restaurar som") == true)
        await h.advance(100); XCTAssertEqual(h.opens, 1)
        h.pauseError = nil; await h.stop(model)
        XCTAssertFalse(model.recoveryPending); XCTAssertTrue(model.ready)
    }

    @MainActor func testPrimaryAndRestoreErrorsAreBothPreserved() async {
        let h = NativeControllerHarness(); h.openFailures = 1; h.restoreError = "restore-recovery"
        let model = await h.start()
        XCTAssertTrue(model.enabled); XCTAssertTrue(model.recoveryPending)
        XCTAssertTrue(model.error?.contains("opening-primary") == true)
        XCTAssertTrue(model.error?.contains("restore-recovery") == true)
        await h.advance(100); XCTAssertEqual(h.opens, 1)
        h.restoreError = nil; await h.stop(model)
    }

    @MainActor func testInitialAndRequestedBackgroundDoNotPauseNewPlayOrNeedPreRequestState() async {
        let h = NativeControllerHarness(); h.playing = true
        let model = await h.start()
        h.notify(.background); await h.settle()
        XCTAssertEqual(h.pauses, 0); XCTAssertEqual(h.requests, 0, "Enabling during playback is a baseline")
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.requests, 1, "Request does not wait for fresh vendor state")
        h.notify(.background, stream: .cisMedia); await h.settle()
        XCTAssertEqual(h.pauses, 0); XCTAssertTrue(h.playing)
        XCTAssertTrue(h.hud.isEmpty)
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac"); XCTAssertEqual(h.hud, ["Conectado ao Mac"])
        XCTAssertFalse(h.commands.contains(SamsungMdePacket.outputDeviceState(.single)))
        XCTAssertFalse(h.commands.contains(SamsungMdePacket.playbackStatus(.playing)))
        await h.stop(model)
    }

    @MainActor func testOwnedSessionUsesOpenChannelAndHALWithoutRepeatedProfilerPolling() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        await h.advance(60)
        XCTAssertTrue(model.enabled); XCTAssertEqual(model.route, "Mac"); XCTAssertTrue(h.armed)
        h.linkError = "profiler-slow"; await h.advance(30)
        XCTAssertTrue(model.enabled); XCTAssertEqual(model.route, "Mac"); XCTAssertTrue(h.armed)
        h.open = false; await h.advance(0.2)
        XCTAssertTrue(model.enabled); XCTAssertTrue(model.busy); XCTAssertFalse(h.armed)
        XCTAssertTrue(model.error?.contains("canal Samsung") == true)
        await h.stop(model)
    }

    @MainActor func testChannelReconnectClearsEvidenceAndCannotReuseOldForeground() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        let old = h.frame
        h.loseChannel(); await h.settle()
        XCTAssertFalse(h.playing); XCTAssertFalse(h.armed); XCTAssertEqual(model.multipointState, -1)
        await h.advance(1)
        XCTAssertEqual(h.opens, 2); XCTAssertEqual(model.multipointState, -1)
        h.play(); await h.advance(0.2)
        old?(.init(command: 0x45, payload: Data(), sequence: 0, isResponse: false, isFragment: false))
        await h.advance(1)
        XCTAssertEqual(h.hud.count, 1); XCTAssertNotEqual(model.route, "Mac")
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac"); XCTAssertEqual(h.hud.count, 2)
        await h.stop(model)
    }

    @MainActor func testCallVetoLastsUntilExplicitNonCallAndRequiresNewPlay() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.notify(.background, stream: .hfp); await h.settle()
        h.play(); await h.advance(100)
        XCTAssertFalse(h.playing); XCTAssertEqual(h.requests, 0)
        h.notify(.background); await h.advance(0.2)
        XCTAssertEqual(h.requests, 0)
        await h.acquire(model)
        h.notify(.foreground, stream: .cisCall); await h.settle()
        XCTAssertFalse(h.playing); XCTAssertNotEqual(model.route, "Mac")
        await h.stop(model)
    }

    @MainActor func testReason132RecoversWithPauseBeforeRestoringAndAllowsNewSession() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.notify(.background, stream: []); await h.settle()
        h.play(); await h.advance(0.2)
        h.notify(.background, reason: 132); await h.settle()
        XCTAssertTrue(model.enabled); XCTAssertTrue(model.busy)
        XCTAssertFalse(h.playing); XCTAssertFalse(h.armed); XCTAssertTrue(h.hud.isEmpty)
        XCTAssertTrue(model.error?.contains("132") == true)
        await h.advance(1); await h.acquire(model)
        await h.stop(model)
    }

    @MainActor func testRepeatedCyclesRequireNewIntentAndHonorAudioLossCooldown() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        for cycle in 1...2 {
            h.notify(.background); await h.settle()
            XCTAssertEqual(model.route, "Galaxy"); XCTAssertFalse(h.playing)
            h.notify(.background); await h.settle() // Duplicate must not pause again.
            let pauses = h.pauses
            await h.advance(0.2)
            await h.advance(3)
            XCTAssertEqual(h.requests, cycle, "Time alone cannot trigger ping-pong")
            h.play(); await h.advance(0.2)
            h.notify(); await h.advance(0.15)
            XCTAssertEqual(h.requests, cycle + 1)
            XCTAssertEqual(h.pauses, pauses)
        }
        XCTAssertEqual(h.hud, ["Conectado ao Mac", "Conectado ao Galaxy", "Conectado ao Mac", "Conectado ao Galaxy", "Conectado ao Mac"])
        await h.stop(model)
    }

    @MainActor func testIntentDuringCooldownWaitsAndRequestsExactlyOnce() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        h.notify(.background); await h.settle()
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.requests, 1)
        await h.advance(3)
        XCTAssertEqual(h.requests, 2, "A new explicit play is retained through cooldown")
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        await h.advance(3)
        XCTAssertEqual(h.requests, 2)
        await h.stop(model)
    }

    @MainActor func testPausingOrCallingCancelsPendingCooldownIntent() async {
        for call in [false, true] {
            let h = NativeControllerHarness(); let model = await h.start()
            await h.acquire(model)
            h.notify(.background); await h.settle()
            h.play(); await h.advance(0.2)
            if call { h.notify(.background, stream: .hfp); await h.settle() }
            else { h.playing = false; await h.advance(0.2) }
            await h.advance(10)
            XCTAssertEqual(h.requests, 1)
            await h.stop(model)
        }
    }

    @MainActor func testAlreadyForegroundNeedsFreshRadioAndExistingMacOutput() async {
        let h = NativeControllerHarness(); h.output = 2
        let model = await h.start()
        h.notify(); await h.settle()
        h.play(); await h.advance(0.2)
        XCTAssertEqual(model.route, "Mac")
        XCTAssertEqual(h.requests, 0, "No changed notification is required for an already connected Mac")
        XCTAssertEqual(h.hud, ["Conectado ao Mac"])
        await h.stop(model)
    }

    @MainActor func testStaleHALWithoutRadioCannotAdoptOldForeground() async {
        let h = NativeControllerHarness(); h.output = 2; h.linked = false
        let model = await h.start()
        h.notify(); await h.settle()
        h.play(); await h.advance(0.2)
        XCTAssertNotEqual(model.route, "Mac")
        XCTAssertTrue(h.hud.isEmpty)
        XCTAssertEqual(h.requests, 1)
        await h.stop(model)
    }

    @MainActor func testDelayedStartupReadCannotConfirmOrUndoAcquisition() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.play(); await h.advance(0.2)
        h.notify(command: 0x44); await h.advance(0.15)
        XCTAssertTrue(h.hud.isEmpty); XCTAssertNotEqual(model.route, "Mac")
        h.notify(); await h.advance(0.15)
        XCTAssertEqual(model.route, "Mac")
        h.notify(.background, command: 0x44); await h.advance(0.2)
        XCTAssertEqual(model.route, "Mac"); XCTAssertTrue(h.playing)
        await h.stop(model)
    }

    @MainActor func testManualRouteOrUnmuteDuringRadioReadIsSafetyStop() async {
        for unmute in [false, true] {
            let h = NativeControllerHarness(); let model = await h.start()
            h.play(); await h.advance(0.2)
            h.linkHook = {
                if unmute { h.verifyError = "manual-unmute" }
                else { h.output = 3 }
            }
            h.notify(); await h.advance(0.15)
            XCTAssertFalse(model.enabled); XCTAssertTrue(h.hud.isEmpty)
            let opens = h.opens; await h.advance(60)
            XCTAssertEqual(h.opens, opens)
            await h.stop(model)
        }
    }

    @MainActor func testPauseDuringRadioOrHALAwaitCannotPublishSuccess() async {
        for hal in [false, true] {
            let h = NativeControllerHarness(); let model = await h.start()
            h.play(); await h.advance(0.2)
            if hal { h.routeHook = { h.playing = false } }
            else { h.linkHook = { h.playing = false } }
            h.notify(); await h.advance(0.15)
            XCTAssertTrue(h.hud.isEmpty); XCTAssertNotEqual(model.route, "Mac")
            await h.stop(model)
        }
    }

    @MainActor func testAdoptionRejectsBackground132AndManualUnmute() async {
        for reject in [false, true] {
            let h = NativeControllerHarness(); h.output = 2
            let model = await h.start()
            h.notify(.background, stream: []); await h.settle()
            h.notify(reject ? .background : .foreground, reason: reject ? 132 : 0)
            if !reject { h.linkHook = { h.verifyError = "manual-unmute" } }
            h.play(); await h.advance(0.2)
            XCTAssertTrue(h.hud.isEmpty); XCTAssertNotEqual(model.route, "Mac")
            if !reject { XCTAssertFalse(model.enabled) }
            await h.stop(model)
        }
    }

    @MainActor func testPausedCurrentPlayerDoesNotUnmuteOtherApplicationAudio() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.otherOutput = true
        await h.stop(model)
        XCTAssertTrue(h.armed); XCTAssertTrue(model.recoveryPending)
        XCTAssertTrue(model.error?.contains("Pausa não confirmada") == true)
        XCTAssertEqual(h.restores, 0)
        h.otherOutput = false; await h.stop(model)
        XCTAssertFalse(h.armed)
    }

    @MainActor func testReleasingHealthyModelReachesCleanupWithoutExplicitStop() async {
        let h = NativeControllerHarness()
        var model: NativeAutoSwitchModel? = await h.start()
        let released = NativeModelWeakReference(model)
        model = nil
        await h.advance(0.2)
        await h.settle()
        XCTAssertNil(released.value)
        XCTAssertFalse(h.armed); XCTAssertFalse(h.open)
    }

    @MainActor func testStopRetainsSettlingStateAndRefusesNewSessionUntilSDKDrains() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.pendingOperations = 1
        await h.stop(model)
        XCTAssertFalse(model.enabled); XCTAssertTrue(model.transportIsSettling)
        model.start(transportGranted: true); await h.settle()
        XCTAssertEqual(h.opens, 1); XCTAssertFalse(model.enabled)
        h.pendingOperations = 0
        XCTAssertFalse(model.transportIsSettling)
        model.start(transportGranted: true); await h.settle()
        XCTAssertEqual(h.opens, 2); XCTAssertTrue(model.enabled)
        await h.stop(model)
    }

    @MainActor func testRecoveryWaitsForSDKDrainWithoutRearmingOrPausingAgain() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.pendingOperations = 1
        h.loseChannel(); await h.settle()
        let arms = h.arms, pauses = h.pauses
        h.play()
        await h.advance(1)
        await h.advance(10)
        XCTAssertEqual(h.arms, arms); XCTAssertEqual(h.pauses, pauses)
        XCTAssertEqual(h.opens, 1); XCTAssertFalse(h.armed); XCTAssertTrue(h.playing)
        h.pendingOperations = 0
        await h.advance(0.25)
        XCTAssertEqual(h.opens, 2); XCTAssertEqual(h.arms, arms + 1)
        XCTAssertTrue(model.enabled)
        await h.stop(model)
    }

    @MainActor func testStartupReadNeverOverwritesNewerCallOrBackgroundNotification() async {
        for call in [false, true] {
            let h = NativeControllerHarness(); h.output = 2
            let model = await h.start()
            h.notify(.background, stream: call ? .hfp : .a2dp); await h.settle()
            h.notify(.foreground, command: 0x44); await h.settle()
            h.play(); await h.advance(0.2)
            XCTAssertTrue(h.hud.isEmpty); XCTAssertNotEqual(model.route, "Mac")
            if call { XCTAssertEqual(h.requests, 0); XCTAssertFalse(h.playing) }
            else { XCTAssertEqual(h.requests, 1) }
            await h.stop(model)
        }
    }

    @MainActor func testNoStatusNeverMeansSuccessAndDeadlineStartsAtRequest() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.advance(20) // Opening/waiting is not the handoff deadline.
        XCTAssertTrue(model.enabled); XCTAssertFalse(model.busy)
        h.play(); await h.advance(0.2)
        XCTAssertEqual(h.requests, 1)
        await h.advance(11.9)
        XCTAssertTrue(model.busy); XCTAssertTrue(h.armed); XCTAssertTrue(h.hud.isEmpty)
        await h.advance(0.1)
        XCTAssertTrue(model.enabled); XCTAssertTrue(model.busy); XCTAssertFalse(h.armed)
        XCTAssertTrue(model.error?.contains("doze segundos") == true)
        await h.stop(model)
    }

    @MainActor func testForegroundInvalidatedDuringRadioOrHALReadCannotShowSuccess() async {
        for duringHAL in [false, true] {
            let h = NativeControllerHarness(); let model = await h.start()
            h.play(); await h.advance(0.2)
            if duringHAL { h.routeHook = { h.notify(.background) } }
            else { h.linkHook = { h.notify(.background) } }
            h.notify(); await h.advance(0.15)
            XCTAssertTrue(h.hud.isEmpty); XCTAssertNotEqual(model.route, "Mac")
            await h.stop(model)
        }
    }

    @MainActor func testStopDuringHandoffCancelsTimeoutAndNeverRestarts() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.play(); await h.advance(0.2)
        XCTAssertTrue(model.busy); XCTAssertTrue(h.armed)
        await h.stop(model); await h.advance(60)
        XCTAssertFalse(model.enabled); XCTAssertFalse(model.busy); XCTAssertFalse(h.armed)
        XCTAssertFalse(h.playing); XCTAssertTrue(h.hud.isEmpty); XCTAssertEqual(h.opens, 1)
    }

    @MainActor func testStopDuringTakeoverPauseDoesNotReportExpectedCancellationAsRecoveryFailure() async {
        let h = NativeControllerHarness(); let model = await h.start()
        await h.acquire(model)
        h.holdPause = true; h.notify(.background); await h.settle()
        model.stop()
        h.holdPause = false; h.pauseGate?.resume(); h.pauseGate = nil
        await h.settle(); await h.advance(60)
        XCTAssertFalse(model.enabled); XCTAssertFalse(model.busy); XCTAssertFalse(h.armed)
        XCTAssertNil(model.error); XCTAssertEqual(h.opens, 1)
    }

    @MainActor func testCallArrivingDuringRequestVetoesForegroundUntilExplicitEnd() async {
        let h = NativeControllerHarness(); let model = await h.start()
        h.play(); await h.advance(0.2)
        h.notify(.foreground, stream: .hfp); await h.advance(0.15)
        XCTAssertFalse(h.playing); XCTAssertTrue(h.hud.isEmpty); XCTAssertTrue(model.enabled)
        h.play(); await h.advance(60)
        XCTAssertEqual(h.requests, 1); XCTAssertFalse(h.playing)
        h.notify(.background); await h.advance(0.2)
        await h.acquire(model)
        await h.stop(model)
    }

    @MainActor func testRepeatedOpeningFailuresActuallyIncreaseControllerDelay() async {
        let h = NativeControllerHarness(); h.openFailures = 3
        let model = await h.start()
        await h.advance(1); XCTAssertEqual(h.opens, 2)
        await h.advance(1.9); XCTAssertEqual(h.opens, 2)
        await h.advance(0.1); XCTAssertEqual(h.opens, 3)
        await h.advance(3.9); XCTAssertEqual(h.opens, 3)
        await h.advance(0.1); XCTAssertEqual(h.opens, 4)
        XCTAssertTrue(model.enabled); XCTAssertFalse(model.busy)
        await h.stop(model)
    }

    @MainActor func testManualGuardOrOutputChangesDoNotAutomaticallyRearm() async {
        for manualUnmute in [false, true] {
            let h = NativeControllerHarness(); let model = await h.start()
            if manualUnmute { h.verifyError = "manual-unmute" }
            else { h.output = 3 }
            await h.advance(0.2)
            XCTAssertFalse(model.enabled); XCTAssertFalse(model.busy); XCTAssertFalse(h.armed)
            await h.advance(100); XCTAssertEqual(h.opens, 1)
            await h.stop(model)
        }
    }

    func testRecoveryBackoffIsCappedAndResetsOnlyAfterStability() {
        var policy = NativeSwitchRecoveryPolicy()
        XCTAssertEqual((0..<10).map { _ in policy.nextDelay() }, [1, 2, 4, 8, 16, 30, 30, 30, 30, 30])
        policy.stable(); XCTAssertEqual(policy.nextDelay(), 1)
        XCTAssertEqual(NativeSwitchRecoveryPolicy.handoffTimeout, 12)
    }
}
