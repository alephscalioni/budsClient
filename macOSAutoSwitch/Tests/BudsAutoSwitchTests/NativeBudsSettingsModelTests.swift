import XCTest
@testable import BudsAutoSwitch

/// Manual time and callbacks. No native transport, processes or devices.
@MainActor private final class SettingsHarness {
    typealias Packet = SamsungBudsSettingsPacket
    struct Callbacks {
        let frame: (Packet.Frame) -> Void
        let written: (UInt) -> Void
        let failed: (NativeBudsError) -> Void
    }
    var time: TimeInterval = 0
    var connected = true
    var connections: [Bool] = []
    var checks: [String] = []
    var opens: [String] = []
    var closes = 0
    var isOpen = false
    var packets: [Data] = []
    var nextWrite: UInt = 0
    var callbacks: Callbacks?
    var sessions: [Callbacks] = []
    var statusOnRead: Packet.Frame? = SettingsWireFixture.status()
    var openingFailure = false
    var sendingFailure = false
    var connectionFailure = false
    var holdOpen = false
    var holdCheck = false
    var openGate: CheckedContinuation<Void, Never>?
    var checkGate: CheckedContinuation<Void, Never>?
    var onCommandOpen: (() -> Void)?
    var toolsAllowed = true
    var resets = 0
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]

    func environment() -> NativeBudsSettingsEnvironment {
        .init(now: { self.time }, date: { Date(timeIntervalSince1970: 1_000 + self.time) },
            sleep: { try await self.sleep($0) }, connected: { address in
                self.checks.append(address)
                if self.holdCheck { await withCheckedContinuation { self.checkGate = $0 } }
                if self.connectionFailure { throw NativeBudsError(message: "Connection observation failed") }
                return self.connections.isEmpty ? self.connected : self.connections.removeFirst()
            }, handlers: { frame, written, failed in
                if let frame, let written, let failed {
                    let value = Callbacks(frame: frame, written: written, failed: failed)
                    self.callbacks = value; self.sessions.append(value)
                } else { self.callbacks = nil }
            }, open: { address in
                self.opens.append(address)
                let saved = self.callbacks
                if self.holdOpen { await withCheckedContinuation { self.openGate = $0 } }
                if self.openingFailure { throw NativeBudsError(message: "RFCOMM opening failed") }
                self.isOpen = true
                // Each transaction uses a read session then one command session.
                if self.opens.count % 2 == 1, let status = self.statusOnRead { saved?.frame(status) }
                else { self.onCommandOpen?() }
            }, send: { packet in
                XCTAssertTrue(self.isOpen)
                if self.sendingFailure { throw NativeBudsError(message: "RFCOMM enqueue failed") }
                self.packets.append(packet); self.nextWrite += 1
                return self.nextWrite
            }, close: { self.closes += 1; self.isOpen = false }, reset: { self.resets += 1; self.isOpen = false },
            toolsPermission: { self.toolsAllowed })
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
    var responseWaiting: Bool { sleepers.values.contains { $0.0 == time + 5 } }
    func waiting(_ seconds: TimeInterval) -> Bool { sleepers.values.contains { abs($0.0 - time - seconds) < 0.0001 } }
    var transactionWaiting: Bool { sleepers.values.contains { $0.0 == time + 30 } }
    var noiseIntervalWaiting: Bool { sleepers.values.contains { abs($0.0 - 1.5) < 0.00001 } }
    func advance(_ seconds: TimeInterval) {
        time += seconds
        let due = sleepers.filter { $0.value.0 <= time }.map(\.key)
        for id in due { sleepers.removeValue(forKey: id)?.1.resume() }
    }
    func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Fake operation did not reach the expected state", file: file, line: line)
    }
    func select(_ model: NativeBudsSettingsModel, address: String = "AA:BB:CC:DD:EE:FF", blocked: Bool = false) {
        model.select(address: address, name: "Galaxy Buds3 Pro", model: "Buds3Pro", blocked: blocked)
    }
}

final class NativeBudsSettingsModelTests: XCTestCase {
    typealias Model = NativeBudsSettingsModel

    @MainActor private func toolHarness(_ placement: UInt8) -> SettingsHarness {
        let h = SettingsHarness(); var data = SettingsWireFixture.status().payload; data[6] = placement
        h.statusOnRead = .init(command: 0x61, payload: data, isFragment: false)
        return h
    }
    @MainActor func testFindUsesSamsungStartThenSideMuteAndRequiresActualStop() async throws {
        for target in NativeBudsToolsPacket.Target.allCases {
            let h = toolHarness(0x22); let model = Model(environment: h.environment()); h.select(model)
            model.perform(.find(target)); await h.until { h.packets.count == 1 && h.responseWaiting }
            XCTAssertEqual(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[0])?.command, 0xA6)
            h.callbacks?.written(h.nextWrite)
            if target != .both {
                await h.until { h.packets.count == 2 && h.responseWaiting }
                XCTAssertEqual(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[1])?.command, 0xA2)
                h.callbacks?.written(h.nextWrite)
                h.callbacks?.frame(SettingsWireFixture.ack(0xA2, [1, 1]))
                XCTAssertEqual(h.packets.count, 2)
                h.callbacks?.frame(SettingsWireFixture.ack(0xA2, target.mute))
            }
            await h.until { model.status.hasPrefix("Procurando") && h.waiting(NativeBudsToolsPacket.findDuration) }
            h.advance(NativeBudsToolsPacket.findDuration)
            let count = target == .both ? 2 : 3
            await h.until { h.packets.count == count && h.responseWaiting }
            XCTAssertEqual(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets.last!)?.command, 0xA1)
            h.callbacks?.frame(.init(command: 0xA1, payload: Data([99]), isFragment: false))
            XCTAssertTrue(model.busy)
            h.callbacks?.written(h.nextWrite); await h.until { !model.busy }
            XCTAssertNil(model.error); XCTAssertTrue(model.status.contains("encerrada"))
            let historical = model.snapshot["last_observation"] as? [String: Any]
            XCTAssertEqual(historical?["noise_mode"] as? String, "ambient")
            XCTAssertEqual(historical?["equalizer"] as? Int, 4)
            XCTAssertFalse(model.snapshot["read_fresh"] as? Bool ?? true,
                "A three-minute search must not redate the earlier settings reading")
            XCTAssertEqual(model.batterySnapshot?.observedAt, 1_000)
            XCTAssertGreaterThan(h.resets, 0)
            model.cancel()
        }
    }
    @MainActor func testFindUnconfirmedStartOrSideSelectionRequestsCleanupWithoutSuccess() async {
        for target in [NativeBudsToolsPacket.Target.both, .left] {
            let h = toolHarness(0x22); let model = Model(environment: h.environment()); h.select(model)
            model.perform(.find(target)); await h.until { h.packets.count == 1 && h.responseWaiting }
            if target == .left {
                h.callbacks?.written(h.nextWrite)
                await h.until { h.packets.count == 2 && h.responseWaiting }; h.callbacks?.written(h.nextWrite)
            }
            h.advance(5); await h.until { !model.busy }
            XCTAssertNotNil(model.error); XCTAssertFalse(model.status.contains("Busca encerrada"))
            XCTAssertGreaterThan(h.resets, 0); model.cancel()
        }
    }
    @MainActor func testEarlyFindStopBeforeStartCompletionNeverSendsSideMute() async {
        let h = toolHarness(0x22); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.find(.left)); await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.frame(.init(command: 0xA1, payload: Data(), isFragment: false))
        h.callbacks?.written(h.nextWrite)
        await h.until { h.packets.count == 2 && h.responseWaiting }
        XCTAssertEqual(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[1])?.command, 0xA1)
        XCTAssertFalse(h.packets.contains { SamsungBudsSettingsPacket.decodeCompleteFrame($0)?.command == 0xA2 })
        h.callbacks?.written(h.nextWrite); await h.until { !model.busy }
        XCTAssertNil(model.error); XCTAssertTrue(model.status.contains("encerrada")); model.cancel()
    }
    @MainActor func testHostFindStopNeedsSDKCompletionWithoutInventedNotificationRequirement() async {
        let h = toolHarness(0x22); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.find(.both)); await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.written(h.nextWrite)
        await h.until { h.waiting(NativeBudsToolsPacket.findDuration) }
        model.perform(["action": "device.tools_cancel"])
        await h.until { h.packets.count == 2 && h.responseWaiting }
        XCTAssertTrue(model.busy)
        h.callbacks?.written(h.nextWrite); await h.until { !model.busy }
        XCTAssertNil(model.error); XCTAssertEqual(model.status, "Parada da busca enviada."); model.cancel()
    }
    @MainActor func testFindWaitsBeyondThreeSecondsAndManualStopTransmitsOriginalA1() async {
        let h = toolHarness(0x22); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.find(.both)); await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.written(h.nextWrite)
        await h.until { h.waiting(NativeBudsToolsPacket.findDuration) }
        h.advance(31); await Task.yield()
        XCTAssertTrue(model.busy); XCTAssertEqual(h.packets.count, 1)
        model.perform(["action": "device.tools_cancel"])
        await h.until { h.packets.count == 2 && h.responseWaiting }
        h.callbacks?.written(h.nextWrite)
        await h.until { !model.busy }; XCTAssertNil(model.error); model.cancel()
    }
    @MainActor func testRemoteFindStopWakesSearchBeforeHostDeadline() async {
        let h = toolHarness(0x22); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.find(.both)); await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.written(h.nextWrite); await h.until { h.waiting(NativeBudsToolsPacket.findDuration) }
        h.callbacks?.frame(.init(command: 0xA1, payload: Data(), isFragment: false))
        await h.until { h.packets.count == 2 }; h.callbacks?.written(h.nextWrite)
        await h.until { !model.busy }; XCTAssertNil(model.error); model.cancel()
    }
    @MainActor func testRemoteFindStopDuringSideMuteDoesNotWaitForAnUnneededMuteEcho() async {
        let h = toolHarness(0x22); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.find(.left)); await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.written(h.nextWrite); await h.until { h.packets.count == 2 && h.responseWaiting }
        h.callbacks?.written(h.nextWrite)
        h.callbacks?.frame(.init(command: 0xA1, payload: Data(), isFragment: false))
        await h.until { h.packets.count == 3 }; h.callbacks?.written(h.nextWrite)
        await h.until { !model.busy }; XCTAssertNil(model.error); model.cancel()
    }
    @MainActor func testToolStartNeedsNoCachedReadingAndFreshWearStillVetoesRing() async {
        let h = toolHarness(0x11); let model = Model(environment: h.environment()); h.select(model)
        h.advance(40)
        XCTAssertEqual((model.snapshot["tools"] as? [String: Any])?["can_find"] as? Bool, true)
        model.perform(.find(.both)); await h.until { !model.busy }
        XCTAssertFalse(h.opens.isEmpty); XCTAssertTrue(h.packets.isEmpty)
        XCTAssertTrue(model.error?.contains("ouvidos") == true); model.cancel()
    }
    @MainActor func testExpiredSearchTimerCannotAbortNewStopWriteWait() async {
        let h = toolHarness(0x22)
        var environment = h.environment(); let originalSleep = environment.sleep
        environment.sleep = { seconds in
            try await originalSleep(seconds)
            if seconds == NativeBudsToolsPacket.findDuration {
                // The timer has returned successfully just as remote stop
                // advances the operation to its new SDK-write wait.
                h.callbacks?.frame(.init(command: 0xA1, payload: Data(), isFragment: false))
                await h.until { h.packets.count == 2 && h.responseWaiting }
            }
        }
        let model = Model(environment: environment); h.select(model)
        model.perform(.find(.both)); await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.written(h.nextWrite); await h.until { h.waiting(NativeBudsToolsPacket.findDuration) }
        h.advance(NativeBudsToolsPacket.findDuration)
        await h.until { h.packets.count == 2 && h.responseWaiting }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(model.busy); XCTAssertNil(model.error)
        h.callbacks?.written(h.nextWrite); await h.until { !model.busy }
        XCTAssertNil(model.error); model.cancel()
    }
    @MainActor func testFitRequiresRealTypedResultAndWriteBeforePublishingThenSendsStop() async throws {
        let h = toolHarness(0x11); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.fitTest); await h.until { h.packets.count == 1 }
        let frame = try XCTUnwrap(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[0]))
        XCTAssertEqual(frame.command, 0x9D); XCTAssertEqual(Array(frame.payload), [1])
        h.callbacks?.frame(.init(command: 0x9E, payload: Data([3, 1]), isFragment: false))
        h.callbacks?.frame(.init(command: 0x9E, payload: Data([1]), isFragment: false))
        h.callbacks?.frame(SettingsWireFixture.ack(0x9D, [1]))
        XCTAssertEqual(h.packets.count, 1)
        h.callbacks?.frame(.init(command: 0x9E, payload: Data([1, 0]), isFragment: false))
        XCTAssertTrue(model.busy)
        XCTAssertTrue((model.snapshot["tools"] as? [String: Any])?["fit_result"] is NSNull)
        h.callbacks?.written(h.nextWrite); await h.until { h.packets.count == 2 }
        XCTAssertEqual(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[1])?.payload, Data([0]))
        h.callbacks?.written(h.nextWrite); await h.until { !model.busy }
        let tools = try XCTUnwrap(model.snapshot["tools"] as? [String: Any])
        XCTAssertEqual(tools["fit_result"] as? [String: String], ["left": "good", "right": "bad"])
        XCTAssertEqual(tools["fit_observed_at"] as? Double, 1_000)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_000); XCTAssertGreaterThan(h.resets, 0)
        model.cancel()
    }
    @MainActor func testToolWearPermissionAndFreshnessGatesRejectBeforeStarting() async {
        for (placement, action) in [(UInt8(0x11), Model.Action.find(.both)), (0x22, .fitTest), (0x12, .fitTest)] {
            let h = toolHarness(placement); let model = Model(environment: h.environment()); h.select(model)
            model.perform(action); await h.until { !model.busy }
            XCTAssertTrue(h.packets.isEmpty); XCTAssertNotNil(model.error); model.cancel()
        }
        for action in [Model.Action.find(.both), .fitTest] {
            let h = toolHarness(action == .fitTest ? 0x11 : 0x22)
            let model = Model(environment: h.environment()); h.select(model)
            h.toolsAllowed = false; model.perform(action)
            XCTAssertTrue(h.opens.isEmpty); XCTAssertTrue(h.packets.isEmpty)
            h.toolsAllowed = true; h.onCommandOpen = { h.advance(6) }
            model.perform(action); await h.until { !model.busy }
            XCTAssertTrue(h.packets.isEmpty); XCTAssertTrue(model.error?.contains("antiga") == true)
            model.cancel()
        }
    }
    @MainActor func testFitTimeoutWearLossPermissionLossAndCancellationFenceOldResults() async throws {
        for scenario in ["timeout", "wear", "permission", "cancel"] {
            let h = toolHarness(0x11); let model = Model(environment: h.environment()); h.select(model)
            model.perform(.fitTest); await h.until { h.packets.count == 1 && h.waiting(8) }
            let old = try XCTUnwrap(h.callbacks)
            old.written(h.nextWrite)
            switch scenario {
            case "timeout": h.advance(8)
            case "wear": old.frame(.init(command: 0x60, payload: Data([1, 0, 0, 0, 0, 0x12]), isFragment: false))
            case "permission":
                h.toolsAllowed = false; old.frame(.init(command: 0x9E, payload: Data([1, 1]), isFragment: false))
            default: model.perform(["action": "device.tools_cancel"])
            }
            await h.until { !model.busy }
            old.frame(.init(command: 0x9E, payload: Data([1, 1]), isFragment: false)); old.written(h.nextWrite)
            XCTAssertTrue((model.snapshot["tools"] as? [String: Any])?["fit_result"] is NSNull)
            XCTAssertEqual(h.packets.count, 1); XCTAssertGreaterThan(h.resets, 0)
            XCTAssertEqual((model.snapshot["tools"] as? [String: Any])?["active"] as? Bool, false)
            model.cancel()
        }
    }

    @MainActor func testPanelCancellationKeepsActualDatedObservationWithoutWritePermission() async throws {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.refresh); await h.until { !model.busy }
        let before = try XCTUnwrap(model.snapshot["last_observation"] as? [String: Any])
        let revision = model.snapshot["observation_revision"] as? UInt64
        XCTAssertEqual(before["noise_mode"] as? String, "ambient")
        model.cancel()
        let state = model.snapshot
        XCTAssertEqual(state["can_control"] as? Bool, false)
        XCTAssertEqual(state["read_fresh"] as? Bool, false)
        XCTAssertTrue(state["observed_at"] is NSNull)
        let cached = try XCTUnwrap(state["last_observation"] as? [String: Any])
        XCTAssertEqual(cached["noise_mode"] as? String, before["noise_mode"] as? String)
        XCTAssertEqual(cached["observed_at"] as? Double, before["observed_at"] as? Double)
        XCTAssertEqual(state["observation_revision"] as? UInt64, revision)
        XCTAssertTrue(h.packets.isEmpty)
    }

    @MainActor func testCacheExpiresWithPhysicalLinkEpochAndCannotBeRestoredByOldCallbacks() async throws {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); let epoch = UUID()
        model.select(address: "AA:BB:CC:DD:EE:FF", name: "Buds", model: "Buds3Pro", blocked: false, connectionEpoch: epoch)
        model.perform(.refresh); await h.until { !model.busy }
        let retired = try XCTUnwrap(h.sessions.first)
        model.cancel()
        model.select(address: "AA:BB:CC:DD:EE:FF", name: "Novo nome", model: "Buds3Pro", blocked: false, connectionEpoch: epoch)
        XCTAssertFalse((model.snapshot["last_observation"] as? [String: Any] ?? [:]).isEmpty)
        model.select(address: "AA:BB:CC:DD:EE:FF", name: "Novo nome", model: "Buds3Pro", blocked: false, connectionEpoch: UUID())
        retired.frame(SettingsWireFixture.status()); retired.written(1); retired.failed(.init(message: "Late error"))
        XCTAssertTrue((model.snapshot["last_observation"] as? [String: Any] ?? [:]).isEmpty)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_000, "Same-device historical charge keeps its original date")
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, false)
    }

    @MainActor func testSuspensionAndFailedRefreshPreserveHistoryButPhysicalLossDiscardsIt() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.refresh); await h.until { !model.busy }
        h.select(model, blocked: true)
        XCTAssertFalse((model.snapshot["last_observation"] as? [String: Any] ?? [:]).isEmpty)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, false)
        XCTAssertEqual(model.snapshot["can_refresh"] as? Bool, false)
        h.select(model); h.openingFailure = true
        model.perform(.refresh); await h.until { !model.busy }
        XCTAssertFalse((model.snapshot["last_observation"] as? [String: Any] ?? [:]).isEmpty)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, false)
        model.invalidateConnection()
        XCTAssertTrue((model.snapshot["last_observation"] as? [String: Any] ?? [:]).isEmpty)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_000)
    }

    @MainActor func testInterruptedWriteNeverTurnsRequestedValueOrLateACKIntoCachedObservation() async throws {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.anc))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        let retired = try XCTUnwrap(h.callbacks)
        model.cancel()
        retired.written(h.nextWrite); retired.frame(SettingsWireFixture.ack(120, [1]))
        retired.frame(SettingsWireFixture.status(equalizer: 1))
        let cached = try XCTUnwrap(model.snapshot["last_observation"] as? [String: Any])
        XCTAssertEqual(cached["noise_mode"] as? String, "ambient")
        XCTAssertEqual(cached["equalizer"] as? Int, 4)
        XCTAssertEqual(cached["settings_may_have_changed"] as? Bool, true)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, false)
        XCTAssertEqual(h.packets.count, 1, "Reopening/cancellation must never replay a pending write")
    }

    @MainActor func testReadFreshnessIsIndependentOfContinuousControlPermissionAndCachedBootstrapRevision() async {
        let h = SettingsHarness(); var environment = h.environment()
        environment.statusTimestamp = { (0, Date(timeIntervalSince1970: 1_000)) }
        h.onCommandOpen = { h.callbacks?.frame(SettingsWireFixture.status()) }
        let model = Model(environment: environment); h.select(model)
        model.perform(.refresh); await h.until { !model.busy }
        let first = model.snapshot["observation_revision"] as? UInt64
        h.advance(1)
        model.perform(.refresh); await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["observation_revision"] as? UInt64, first, "A cached bootstrap does not renew the retry budget")
        h.advance(31)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, true)
        XCTAssertEqual(model.snapshot["read_fresh"] as? Bool, false)
        model.cancel()
    }

    @MainActor func testAddressRoundTripCannotReuseOldDeviceObservations() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.refresh); await h.until { !model.busy }
        h.select(model, address: "11:22:33:44:55:66")
        h.select(model)
        XCTAssertTrue((model.snapshot["last_observation"] as? [String: Any] ?? [:]).isEmpty)
        XCTAssertNil(model.batterySnapshot)
        model.cancel()
    }

    func testScalarSettingJSONRejectsUnknownKeysWrongTypesAndOutOfRangeTimeout() throws {
        func action(_ json: String) throws -> Model.Action? {
            Model.Action.parse(try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any])
        }
        XCTAssertEqual(try action(#"{"action":"device.setting","key":"sidetone","value":true}"#), .setting(.sidetone, 1))
        XCTAssertEqual(try action(#"{"action":"device.setting","key":"conversation_timeout","value":2}"#), .setting(.conversationTimeout, 2))
        for json in [
            #"{"action":"device.setting","key":"sidetone","value":1}"#,
            #"{"action":"device.setting","key":"sidetone","value":"true"}"#,
            #"{"action":"device.setting","key":"conversation_timeout","value":true}"#,
            #"{"action":"device.setting","key":"conversation_timeout","value":1.5}"#,
            #"{"action":"device.setting","key":"conversation_timeout","value":3}"#,
            #"{"action":"device.setting","key":"seamless_connection","value":false}"#
        ] { XCTAssertNil(try action(json)) }
    }

    @MainActor func testOriginalScalarCommandsPublishOnlyAfterExactAckAndWriteCompletion() async throws {
        let cases: [(SamsungBudsSettingsPacket.Setting, Int, UInt8, UInt8)] = [
            (.conversationDetection, 1, 122, 1), (.conversationTimeout, 2, 123, 2),
            (.oneEarbudNoiseControl, 1, 111, 1), (.sidetone, 1, 139, 1), (.callAudioToBuds, 0, 110, 1)
        ]
        for (setting, value, command, wire) in cases {
            let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
            model.perform(.setting(setting, value))
            await h.until { h.packets.count == 1 && h.responseWaiting }
            let packet = try XCTUnwrap(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[0]))
            XCTAssertEqual(packet.command, command); XCTAssertEqual(packet.payload, Data([wire]))
            h.callbacks?.frame(SettingsWireFixture.ack(command, [wire ^ 1]))
            h.callbacks?.written(h.nextWrite)
            XCTAssertTrue(model.busy, "A different echo is not confirmation")
            h.callbacks?.frame(SettingsWireFixture.ack(command, [wire]))
            await h.until { !model.busy }
            XCTAssertNil(model.error)
            let settings = try XCTUnwrap(model.snapshot["settings"] as? [String: Any])
            if setting.isBoolean { XCTAssertEqual(settings[setting.rawValue] as? Bool, value == 1) }
            else { XCTAssertEqual(settings[setting.rawValue] as? Int, value) }
            model.cancel()
        }
    }

    @MainActor func testUnobservedScalarSettingCannotSend() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        var future = SettingsWireFixture.status().payload; future[0] = 5
        h.statusOnRead = .init(command: 0x61, payload: future, isFragment: false)
        model.perform(.setting(.sidetone, 1)); await h.until { !model.busy }
        XCTAssertTrue(h.packets.isEmpty); XCTAssertNotNil(model.error)
        model.cancel()
    }

    @MainActor func testLateScalarAckCannotSurviveSelectionChange() async throws {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.setting(.sidetone, 1)); await h.until { h.packets.count == 1 && h.responseWaiting }
        let old = try XCTUnwrap(h.callbacks)
        h.select(model, address: "11:22:33:44:55:66")
        old.frame(SettingsWireFixture.ack(139, [1])); old.written(h.nextWrite)
        XCTAssertFalse(model.busy)
        XCTAssertTrue((model.snapshot["settings"] as? [String: Any])?.isEmpty == true)
    }

    @MainActor func testTouchAvailabilityExpiresWithItsPreservedGestureObservation() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.refresh)
        await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["can_touch"] as? Bool, true)
        let opens = h.opens.count
        h.advance(15.01)
        XCTAssertEqual(model.snapshot["can_touch"] as? Bool, false)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, true)
        XCTAssertEqual(h.opens.count, opens, "Polling availability cannot reconnect or manufacture a fresh observation")
        model.cancel()
    }

    @MainActor func testPairedAliasAndModelMetadataUpgradeDoNotEraseVerifiedSettings() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment())
        model.select(address: "AA:BB:CC:DD:EE:FF", name: "Buds de Aleph", model: nil, blocked: false)
        model.perform(.refresh)
        await h.until { !model.busy }
        let before = model.snapshot["noise_mode"] as? String
        XCTAssertNotNil(before)
        model.select(address: "AA:BB:CC:DD:EE:FF", name: "Buds3 Pro de Aleph", model: "Buds3Pro", blocked: false)
        XCTAssertEqual(model.snapshot["noise_mode"] as? String, before)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, true)
        model.cancel()
    }

    @MainActor func testPairedAliasUpdateCannotCancelPendingMatchingCommand() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.anc))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        model.select(address: "AA:BB:CC:DD:EE:FF", name: "Buds3 Pro renamed", model: "Buds3Pro", blocked: false)
        XCTAssertTrue(model.busy)
        h.callbacks?.frame(SettingsWireFixture.ack(0x78, [1]))
        h.callbacks?.written(h.nextWrite)
        await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["noise_mode"] as? String, "anc")
        XCTAssertNil(model.error)
        model.cancel()
    }


    @MainActor func testSnapshotAndDisconnectedRefreshNeverOpenOrPollRadio() async {
        let h = SettingsHarness(); h.connected = false
        let model = Model(environment: h.environment()); h.select(model)
        for _ in 0..<20 { XCTAssertEqual(model.snapshot["can_control"] as? Bool, false) }
        XCTAssertTrue(h.checks.isEmpty); XCTAssertTrue(h.opens.isEmpty)
        XCTAssertTrue(model.snapshot["connected"] is NSNull)
        model.perform(.refresh)
        await h.until { !model.busy }
        XCTAssertEqual(h.checks.count, 1)
        XCTAssertTrue(h.opens.isEmpty); XCTAssertTrue(h.packets.isEmpty)
        XCTAssertEqual(model.snapshot["connected"] as? Bool, false)
        XCTAssertTrue(model.snapshot["noise_mode"] is NSNull)
        h.advance(31)
        for _ in 0..<20 { XCTAssertTrue(model.snapshot["connected"] is NSNull) }
        XCTAssertEqual(h.checks.count, 1)
        XCTAssertEqual(model.snapshot["can_refresh"] as? Bool, true, "Explicit refresh remains possible while disconnected/stale")
        model.cancel()
    }

    @MainActor func testRefreshPublishesActualPartialBatteriesAndDisabledEQHonestly() async throws {
        let h = SettingsHarness(); h.statusOnRead = SettingsWireFixture.status(equalizer: 0)
        let model = Model(environment: h.environment()); h.select(model)
        model.perform(.refresh)
        await h.until { !model.busy }
        XCTAssertEqual(h.opens.count, 1); XCTAssertTrue(h.packets.isEmpty)
        XCTAssertFalse(h.isOpen)
        XCTAssertEqual(model.snapshot["connected"] as? Bool, true)
        XCTAssertTrue(model.snapshot["equalizer"] is NSNull)
        XCTAssertTrue(model.status.contains("desligado"))
        XCTAssertEqual(model.batterySnapshot?.left, 0)
        XCTAssertEqual(model.batterySnapshot?.right, 100)
        XCTAssertEqual(model.batterySnapshot?.casePercent, 53)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_000)
        let data = try JSONSerialization.data(withJSONObject: model.snapshot)
        XCTAssertFalse(data.isEmpty)
        h.advance(31)
        XCTAssertTrue(model.snapshot["connected"] is NSNull)
        XCTAssertEqual(h.checks.count, 1, "Freshness expiry must never reconnect")
        model.cancel()
    }

    @MainActor func testCommandRequiresMatchingEchoAndExactWriteCompletionInSeparateSession() async throws {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        // An echo delivered while opening is stale/unarmed, even if it matches.
        h.onCommandOpen = { h.callbacks?.frame(SettingsWireFixture.ack(0x78, [1])) }
        model.perform(.noise(.anc))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        XCTAssertEqual(h.opens.count, 2); XCTAssertEqual(h.checks.count, 2)
        let frame = try XCTUnwrap(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[0]))
        XCTAssertEqual(frame.command, 0x78); XCTAssertEqual(frame.payload, Data([1]))
        model.perform(.equalizer(0)) // Busy intents must not queue up.
        h.callbacks?.written(h.nextWrite)
        XCTAssertTrue(model.busy, "Echo received before send cannot confirm the command")
        h.callbacks?.frame(SettingsWireFixture.ack(0x78, [0]))
        h.callbacks?.frame(SettingsWireFixture.ack(0x86, [1]))
        h.callbacks?.frame(.init(command: 0x77, payload: Data([1]), isFragment: false))
        h.sessions[0].frame(SettingsWireFixture.ack(0x78, [1]))
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.snapshot["noise_mode"] as? String, "ambient", "Never optimistically select the requested mode")
        h.callbacks?.frame(SettingsWireFixture.ack(0x78, [1]))
        await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["noise_mode"] as? String, "anc")
        XCTAssertTrue(model.snapshot["error"] is NSNull)
        XCTAssertEqual(h.packets.count, 1); XCTAssertFalse(h.isOpen)
        model.cancel()
    }

    @MainActor func testCorrectACKWithoutWriteCompletionAndWrongWriteIDCannotSucceed() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.equalizer(5))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.frame(SettingsWireFixture.ack(0x86, [6]))
        h.callbacks?.written(h.nextWrite + 10)
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.snapshot["equalizer"] as? Int, 4)
        h.advance(5)
        await h.until { !model.busy }
        XCTAssertNotNil(model.error); XCTAssertTrue(model.snapshot["equalizer"] is NSNull)
        XCTAssertFalse(h.isOpen)
        model.cancel()
    }

    @MainActor func testRapidNoiseChangesWaitSamsungIntervalAfterConfirmedCompletion() async throws {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.off)); await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.written(1); h.callbacks?.frame(SettingsWireFixture.ack(0x78, [0])); await h.until { !model.busy }
        h.advance(0.3)
        var off = SettingsWireFixture.status().payload; off[12] = 0
        h.statusOnRead = .init(command: 0x61, payload: off, isFragment: false)
        model.perform(.noise(.anc)); await h.until { h.noiseIntervalWaiting }
        XCTAssertTrue(model.busy); XCTAssertEqual(h.packets.count, 1)
        XCTAssertEqual(h.opens.count, 2, "The interval must precede the next SDK session, not just its write")
        h.advance(1.19); for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.packets.count, 1)
        h.advance(0.01); await h.until { h.packets.count == 2 && h.responseWaiting }
        let sent = try XCTUnwrap(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[1]))
        XCTAssertEqual(sent.payload, Data([1]))
        h.callbacks?.frame(SettingsWireFixture.ack(0xC9, [0])); h.callbacks?.written(2)
        XCTAssertTrue(model.busy, "Unrelated Samsung traffic cannot confirm noise mode")
        h.callbacks?.frame(SettingsWireFixture.ack(0x78, [1])); await h.until { !model.busy }
        XCTAssertNil(model.error); XCTAssertEqual(model.snapshot["noise_mode"] as? String, "anc")
        model.cancel()
    }

    @MainActor func testCancellationOrSelectionDuringNoiseIntervalCannotSendLater() async {
        for changeSelection in [false, true] {
            let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
            model.perform(.noise(.off)); await h.until { h.packets.count == 1 && h.responseWaiting }
            h.callbacks?.written(1); h.callbacks?.frame(SettingsWireFixture.ack(0x78, [0])); await h.until { !model.busy }
            model.perform(.noise(.anc)); await h.until { h.noiseIntervalWaiting }
            if changeSelection { h.select(model, address: "11:22:33:44:55:66") } else { model.cancel() }
            h.advance(2); for _ in 0..<30 { await Task.yield() }
            XCTAssertFalse(model.busy); XCTAssertEqual(h.packets.count, 1)
            model.cancel()
        }
    }

    @MainActor func testUnrelatedAcknowledgementCannotConfirmOrFalselyRejectNoise() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.anc)); await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.written(1); h.callbacks?.frame(SettingsWireFixture.ack(0xC9, [0]))
        XCTAssertTrue(model.busy)
        h.advance(5); await h.until { !model.busy }
        XCTAssertTrue(model.error?.contains("Sem confirmação") == true)
        XCTAssertFalse(model.error?.contains("divergente") == true)
        XCTAssertTrue(model.snapshot["noise_mode"] is NSNull)
        model.cancel()
    }

    @MainActor func testConflictingNoiseNotificationCannotBeOverwrittenByEchoConfirmation() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.anc))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.frame(.init(command: 0x77, payload: Data([2]), isFragment: false))
        h.callbacks?.frame(SettingsWireFixture.ack(0x78, [1]))
        h.callbacks?.written(h.nextWrite)
        XCTAssertTrue(model.busy)
        h.advance(5)
        await h.until { !model.busy }
        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.snapshot["noise_mode"] is NSNull)
        model.cancel()
    }

    @MainActor func testWrongEchoAndGenericSuccessByteTimeoutAsUnverified() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.adaptive))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.written(h.nextWrite)
        h.callbacks?.frame(SettingsWireFixture.ack(0x78, [0]))
        h.callbacks?.frame(SettingsWireFixture.ack(0xAF, [0]))
        h.advance(5)
        await h.until { !model.busy }
        XCTAssertTrue(model.error?.contains("divergente") == true)
        XCTAssertTrue(model.snapshot["noise_mode"] is NSNull)
        XCTAssertEqual(h.opens.count, 2, "No retry loop after an unverified command")
        h.advance(300)
        XCTAssertEqual(h.opens.count, 2)
        model.cancel()
    }

    @MainActor func testMediaSwitchUsesSamsungUIFieldsAndRequiresFullEcho() async throws {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.mediaControls(false))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        let sent = try XCTUnwrap(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[0]))
        XCTAssertEqual(sent.command, 0x90)
        XCTAssertEqual(sent.payload, Data([1, 0, 0, 0, 1, 0, 1, 0, 2, 3]))
        h.callbacks?.written(h.nextWrite)
        h.callbacks?.frame(SettingsWireFixture.ack(0x90, [0, 0, 0, 0, 1, 0, 1, 0, 2, 3]))
        XCTAssertTrue(model.busy, "An echo changing the master is not the requested media operation")
        h.callbacks?.frame(SettingsWireFixture.ack(0x90, Array(sent.payload)))
        await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["touch_enabled"] as? Bool, true)
        XCTAssertEqual(model.snapshot["media_controls_enabled"] as? Bool, false)
        XCTAssertEqual(model.snapshot["media_controls_mixed"] as? Bool, false)
        let history = try XCTUnwrap(model.snapshot["last_observation"] as? [String: Any])
        XCTAssertTrue(history["media_controls_enabled"] is NSNull)
        XCTAssertEqual(history["media_controls_mixed"] as? Bool, true)
        XCTAssertEqual(history["settings_may_have_changed"] as? Bool, true)
        model.cancel()
    }

    func testIndividualGestureParsingRequiresKnownNameAndActualJSONBoolean() {
        for gesture in SamsungBudsSettingsPacket.Gesture.allCases {
            XCTAssertEqual(Model.Action.parse(["action": "device.gesture", "gesture": gesture.rawValue, "enabled": true]), .gesture(gesture, true))
            for value: Any in [0, 1, "true", NSNull()] {
                XCTAssertNil(Model.Action.parse(["action": "device.gesture", "gesture": gesture.rawValue, "enabled": value]))
            }
        }
        XCTAssertNil(Model.Action.parse(["action": "device.gesture", "gesture": "lighting", "enabled": true]))
    }

    @MainActor func testEachIndividualGestureNeedsFullAckAndWriteCompletionAndPreservesHistoryDate() async throws {
        typealias Packet = SamsungBudsSettingsPacket
        for gesture in Packet.Gesture.allCases {
            let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
            let controls = try XCTUnwrap(Packet.status(h.statusOnRead!, model: "Buds3Pro")?.touchControls)
            let value = !(controls.fields[gesture.rawValue]!)
            let payload = controls.payload(changing: gesture, enabled: value)
            model.perform(.gesture(gesture, value))
            await h.until { h.packets.count == 1 && h.responseWaiting }
            let sent = try XCTUnwrap(Packet.decodeCompleteFrame(h.packets[0]))
            XCTAssertEqual(sent.command, 0x90); XCTAssertEqual(Array(sent.payload), payload)
            let history = model.snapshot["last_observation"] as? [String: Any]
            var wrong = payload; wrong[9] ^= 1
            h.callbacks?.frame(SettingsWireFixture.ack(0x90, wrong))
            XCTAssertTrue(model.busy)
            h.callbacks?.frame(SettingsWireFixture.ack(0x90, payload))
            XCTAssertTrue(model.busy, "An ACK without SDK write completion cannot confirm a gesture")
            h.callbacks?.written(h.nextWrite); await h.until { !model.busy }
            let state = try XCTUnwrap(model.snapshot["touch_controls"] as? [String: Bool])
            XCTAssertEqual(state[gesture.rawValue], value)
            XCTAssertEqual(state, controls.replacing(with: payload)?.fields)
            XCTAssertEqual(model.snapshot["observed_at"] as? Double, history?["observed_at"] as? Double)
            XCTAssertEqual(model.batterySnapshot?.observedAt, 1_000)
            let old = (model.snapshot["last_observation"] as? [String: Any])?["touch_controls"] as? [String: Bool]
            XCTAssertEqual(old, controls.fields, "Confirmation must not rewrite the preceding real observation")
            model.cancel()
        }
    }

    @MainActor func testIndividualGesturesRefuseSlowOpenAndCannotConfirmAfterCancellation() async throws {
        for gesture in SamsungBudsSettingsPacket.Gesture.allCases {
            let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
            h.onCommandOpen = { h.advance(16) }
            model.perform(.gesture(gesture, false)); await h.until { !model.busy }
            XCTAssertTrue(h.packets.isEmpty); XCTAssertTrue(model.error?.contains("antiga") == true)
            h.onCommandOpen = nil
            model.perform(.gesture(gesture, false)); await h.until { h.packets.count == 1 && h.responseWaiting }
            let old = try XCTUnwrap(h.callbacks)
            let payload = try XCTUnwrap(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[0])).payload
            model.cancel()
            old.frame(SettingsWireFixture.ack(0x90, Array(payload))); old.written(h.nextWrite)
            XCTAssertEqual(model.snapshot["can_control"] as? Bool, false)
            XCTAssertTrue((model.snapshot["touch_controls"] as? [String: Bool] ?? [:]).isEmpty)
        }
    }

    @MainActor func testTouchChangesOnlyMasterFlagAndRequiresFullTenByteEcho() async throws {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.touch(false))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        let sent = try XCTUnwrap(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[0]))
        XCTAssertEqual(sent.command, 0x90)
        XCTAssertEqual(sent.payload, Data([0, 1, 1, 0, 1, 0, 1, 0, 2, 3]))
        h.callbacks?.written(h.nextWrite)
        h.callbacks?.frame(SettingsWireFixture.ack(0x90, [0]))
        h.callbacks?.frame(SettingsWireFixture.ack(0x90, [0, 1, 1, 0, 1, 1, 1, 0, 2, 3]))
        XCTAssertTrue(model.busy)
        XCTAssertEqual(model.snapshot["touch_enabled"] as? Bool, true)
        h.callbacks?.frame(SettingsWireFixture.ack(0x90, [0, 1, 1, 0, 1, 0, 1, 0, 2, 3]))
        await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["touch_enabled"] as? Bool, false)
        XCTAssertEqual(h.packets.count, 1)
        model.cancel()
    }

    @MainActor func testUnrepresentableTouchControlsExplicitlyDisableSetterBeforeAnyWrite() async {
        let h = SettingsHarness(); h.statusOnRead = .init(command: 0x61, payload: Data(SettingsWireFixture.status(touch: 0xED).payload.prefix(52)), isFragment: false)
        let model = Model(environment: h.environment()); h.select(model)
        model.perform(.touch(false))
        await h.until { !model.busy }
        XCTAssertTrue(h.packets.isEmpty); XCTAssertEqual(h.opens.count, 1)
        XCTAssertTrue(model.error?.contains("preservar") == true)
        model.cancel()
    }

    @MainActor func testNewerCommandSessionTouchStateWinsOverPriorRead() async throws {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        h.onCommandOpen = { h.callbacks?.frame(SettingsWireFixture.status(touch: 0x12)) }
        model.perform(.touch(true))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        let sent = try XCTUnwrap(SamsungBudsSettingsPacket.decodeCompleteFrame(h.packets[0]))
        XCTAssertEqual(sent.payload, Data([1, 0, 0, 1, 0, 1, 0, 0, 2, 3]), "Preserve the newer tap and call flags")
        h.callbacks?.frame(SettingsWireFixture.ack(0x90, [1, 0, 0, 1, 0, 1, 0, 0, 2, 3]))
        h.callbacks?.written(h.nextWrite)
        await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["touch_enabled"] as? Bool, true)
        model.cancel()
    }

    @MainActor func testSlowCommandOpenCannotWriteUsingOldState() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        h.onCommandOpen = { h.advance(16) }
        model.perform(.touch(false))
        await h.until { !model.busy }
        XCTAssertTrue(h.packets.isEmpty)
        XCTAssertTrue(model.error?.contains("antiga") == true)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_000, "Keep the receive date, not the later open date")
        model.cancel()
    }

    @MainActor func testSelectionCancellationFencesLateOpenStatusFailureAndACK() async {
        let h = SettingsHarness(); h.holdOpen = true
        let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.anc))
        await h.until { h.openGate != nil }
        let old = h.sessions[0]
        h.select(model, address: "11:22:33:44:55:66")
        XCTAssertFalse(model.busy)
        h.holdOpen = false
        h.openGate?.resume(); h.openGate = nil
        old.frame(SettingsWireFixture.status())
        old.written(1)
        old.failed(.init(message: "Late old-session failure"))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(h.packets.isEmpty)
        XCTAssertNil(model.batterySnapshot)
        XCTAssertTrue(model.snapshot["noise_mode"] is NSNull)
        XCTAssertNil(model.error)
        model.cancel()
    }

    @MainActor func testOldCommandSessionCannotConfirmNewGenerationWithSameCommand() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.anc))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        let old = h.sessions[1]
        model.cancel()
        model.perform(.noise(.anc))
        await h.until { h.packets.count == 2 && h.responseWaiting }
        old.frame(SettingsWireFixture.ack(0x78, [1])); old.written(1)
        XCTAssertTrue(model.busy)
        h.callbacks?.frame(SettingsWireFixture.ack(0x78, [1]))
        h.callbacks?.written(1) // Even a current callback with an old write ID is stale.
        XCTAssertTrue(model.busy)
        h.callbacks?.written(2)
        await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["noise_mode"] as? String, "anc")
        XCTAssertEqual(h.packets.count, 2)
        model.cancel()
    }

    @MainActor func testWholeDeadlineReleasesBusyEvenWhenConnectionCheckIgnoresCancellation() async {
        let h = SettingsHarness(); h.holdCheck = true
        let model = Model(environment: h.environment()); h.select(model)
        model.perform(.refresh)
        await h.until { h.checkGate != nil && h.transactionWaiting }
        h.advance(30)
        await h.until { !model.busy }
        XCTAssertNotNil(model.error); XCTAssertTrue(h.opens.isEmpty)
        h.checkGate?.resume(); h.checkGate = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(h.opens.isEmpty)
        XCTAssertTrue(model.snapshot["connected"] is NSNull)
        model.cancel()
    }

    @MainActor func testReadTimeoutWrongModelOrFragmentCannotAuthorizeAnyWrite() async {
        let h = SettingsHarness()
        h.statusOnRead = .init(command: 0x61, payload: SettingsWireFixture.status().payload, isFragment: true)
        let model = Model(environment: h.environment()); h.select(model)
        model.perform(.equalizer(0))
        await h.until { h.responseWaiting }
        h.callbacks?.frame(.init(command: 0x61, payload: Data([0, 0, 80]), isFragment: false))
        h.callbacks?.frame(SettingsWireFixture.ack(0x86, [1]))
        h.advance(5)
        await h.until { !model.busy }
        XCTAssertTrue(h.packets.isEmpty); XCTAssertNotNil(model.error)
        XCTAssertNil(model.batterySnapshot)
        model.cancel()
    }

    @MainActor func testWholeDeadlineDuringNoncooperativeOpenPreventsLateWrite() async {
        let h = SettingsHarness(); h.holdOpen = true
        let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.anc))
        await h.until { h.openGate != nil && h.transactionWaiting }
        let old = h.sessions[0]
        h.advance(30)
        await h.until { !model.busy }
        XCTAssertNotNil(model.error)
        old.frame(SettingsWireFixture.status())
        old.frame(SettingsWireFixture.ack(0x78, [1])); old.written(1)
        h.openGate?.resume(); h.openGate = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(h.opens.count, 1); XCTAssertTrue(h.packets.isEmpty)
        XCTAssertTrue(model.snapshot["noise_mode"] is NSNull)
        model.cancel()
    }

    @MainActor func testSelectionChangeDuringConnectionObservationPreventsAnyOpen() async {
        let h = SettingsHarness(); h.holdCheck = true
        let model = Model(environment: h.environment()); h.select(model)
        model.perform(.touch(false))
        await h.until { h.checkGate != nil }
        h.select(model, address: "11:22:33:44:55:66")
        h.checkGate?.resume(); h.checkGate = nil
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(model.busy)
        XCTAssertTrue(h.opens.isEmpty); XCTAssertTrue(h.packets.isEmpty)
        XCTAssertTrue(model.snapshot["connected"] is NSNull)
        model.cancel()
    }

    @MainActor func testDisconnectBetweenReadAndWriteDoesNotOpenCommandSession() async {
        let h = SettingsHarness(); h.connections = [true, false]
        let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.off))
        await h.until { !model.busy }
        XCTAssertEqual(h.checks.count, 2); XCTAssertEqual(h.opens.count, 1)
        XCTAssertTrue(h.packets.isEmpty); XCTAssertNotNil(model.error)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_000, "Keep actual dated battery readings, not connection permission")
        model.cancel()
    }

    @MainActor func testOpeningEnqueueAndWriteErrorsNeverBecomeACKSuccess() async {
        for failure in 0..<3 {
            let h = SettingsHarness(); h.openingFailure = failure == 0; h.sendingFailure = failure == 1
            let model = Model(environment: h.environment()); h.select(model)
            model.perform(.noise(.anc))
            if failure == 2 {
                await h.until { h.packets.count == 1 && h.responseWaiting }
                h.callbacks?.frame(SettingsWireFixture.ack(0x78, [1]))
                h.callbacks?.failed(.init(message: "OS write failed"))
            }
            await h.until { !model.busy }
            XCTAssertNotNil(model.error); XCTAssertTrue(model.snapshot["noise_mode"] is NSNull)
            XCTAssertFalse(h.isOpen)
            XCTAssertEqual(h.packets.count, failure == 2 ? 1 : 0)
            model.cancel()
        }
    }

    @MainActor func testNameAndBatteryModelHintWithoutPhysicalColorsNeverAuthorizeWrites() async {
        let h = SettingsHarness()
        var payload = SettingsWireFixture.status().payload
        for index in 14...17 { payload[index] = 0 }
        h.statusOnRead = .init(command: 0x61, payload: payload, isFragment: false)
        let model = Model(environment: h.environment()); h.select(model)
        model.perform(.noise(.anc)); await h.until { !model.busy }
        XCTAssertTrue(h.packets.isEmpty)
        XCTAssertEqual(h.opens.count, 1)
        XCTAssertTrue(model.error?.contains("físico") == true)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, false)
        model.cancel()
    }

    @MainActor func testUnsupportedModelAndBusySwitchBlockAllSettingsEffects() async {
        let h = SettingsHarness(); let model = Model(environment: h.environment())
        model.select(address: "AA:BB:CC:DD:EE:FF", name: "Galaxy Buds3 Pro", model: "Buds2Pro", blocked: false)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, false)
        model.perform(.refresh)
        XCTAssertFalse(model.busy); XCTAssertTrue(h.checks.isEmpty)
        h.select(model, blocked: true)
        model.perform(.noise(.anc))
        XCTAssertFalse(model.busy); XCTAssertTrue(h.checks.isEmpty)
        h.select(model)
        h.holdOpen = true
        model.perform(.refresh)
        await h.until { h.openGate != nil }
        h.select(model, blocked: true)
        XCTAssertFalse(model.busy); XCTAssertFalse(h.isOpen)
        h.openGate?.resume(); h.openGate = nil
        model.cancel()
    }

    @MainActor func testMalformedJSONActionsNeverReachTransport() {
        let h = SettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        let invalid: [[String: Any]] = [
            ["action": "device.noise", "mode": "ANC"], ["action": "device.noise", "mode": 1],
            ["action": "device.equalizer", "preset": true], ["action": "device.equalizer", "preset": 0.5],
            ["action": "device.equalizer", "preset": 6], ["action": "device.equalizer", "preset": "0"],
            ["action": "device.touch", "enabled": 1], ["action": "device.touch", "enabled": "true"],
            ["action": "device.touch", "enabled": NSNull()], ["action": "device.unknown"],
            ["action": "device.media_controls", "enabled": 1], ["action": "device.media_controls", "enabled": "true"]
        ]
        for request in invalid { model.perform(request); XCTAssertFalse(model.busy) }
        XCTAssertTrue(h.checks.isEmpty); XCTAssertTrue(h.opens.isEmpty); XCTAssertTrue(h.packets.isEmpty)
        XCTAssertEqual(Model.Action.parse(["action": "device.noise", "mode": "adaptive"]), .noise(.adaptive))
        XCTAssertEqual(Model.Action.parse(["action": "device.equalizer", "preset": 0]), .equalizer(0))
        XCTAssertEqual(Model.Action.parse(["action": "device.touch", "enabled": false]), .touch(false))
        XCTAssertEqual(Model.Action.parse(["action": "device.media_controls", "enabled": false]), .mediaControls(false))
        model.cancel()
    }
}
