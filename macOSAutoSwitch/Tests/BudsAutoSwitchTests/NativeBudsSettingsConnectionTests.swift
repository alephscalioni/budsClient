import XCTest
@testable import BudsAutoSwitch

@MainActor private final class RetainedSettingsHarness {
    typealias Packet = SamsungBudsSettingsPacket
    struct Callbacks {
        let frame: (Packet.Frame) -> Void
        let written: (UInt) -> Void
        let failed: (NativeBudsError) -> Void
    }
    var callbacks: [Callbacks] = []
    var open = false
    var opens = 0
    var closes = 0
    var time: TimeInterval = 10
    var bootstrap: Packet.Frame? = SettingsWireFixture.status()
    var packets: [Data] = []
    var writeID: UInt = 0
    // An independent owner is deliberately outside the settings effects.
    var smepOpen = true
    lazy var connection = NativeBudsSettingsConnection(effects: .init(bind: { [unowned self] in
        self.callbacks.append(.init(frame: $0, written: $1, failed: $2))
    }, open: { [unowned self] _ in
        self.opens += 1; self.open = true
        if let bootstrap = self.bootstrap { self.callbacks.last?.frame(bootstrap) }
    }, isOpen: { [unowned self] in self.open }, send: { [unowned self] bytes in
        self.packets.append(bytes); self.writeID += 1; return self.writeID
    }, close: { [weak self] in self?.closes += 1; self?.open = false },
        now: { [unowned self] in self.time }, date: { [unowned self] in Date(timeIntervalSince1970: 1_000 + self.time) }))
    func environment() -> NativeBudsSettingsEnvironment {
        let connection = connection
        return .init(now: { self.time }, date: { Date(timeIntervalSince1970: 1_000 + self.time) },
            sleep: { try await Task.sleep(for: .seconds($0)) }, connected: { _ in true },
            handlers: { connection.handlers($0, $1, $2) }, open: { try await connection.open($0) },
            send: { try connection.send($0) }, close: { connection.releaseTransaction() }, reset: { connection.reset() },
            statusTimestamp: { connection.observation }, continuousStatus: { connection.continuous }, sessionAlive: { connection.alive })
    }
    func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 { if predicate() { return }; await Task.yield() }
        XCTFail("Retained session did not reach expected state", file: file, line: line)
    }
}

final class NativeBudsSettingsConnectionTests: XCTestCase {
    typealias Packet = SamsungBudsSettingsPacket

    @MainActor func testCustomCurveAndFirmwareTraverseRealConnectionGateWithoutFalsifyingRetainedStatus() async throws {
        let h = RetainedSettingsHarness()
        let model = NativeBudsSettingsModel(environment: h.environment())
        model.select(address: "AABBCCDDEEFF", name: "Galaxy Buds3 Pro", model: "Buds3Pro", blocked: false)
        let bands = [-10, -5, -1, 0, 1, 5, 10, 0, -10]
        model.perform(.customEqualizer(bands)); await h.until { h.packets.count == 1 || model.error != nil }
        XCTAssertNil(model.error)
        XCTAssertEqual(h.packets.first, SamsungBudsCustomEqualizer.writeRequest(bands))
        h.callbacks.last?.written(1); await h.until { h.packets.count == 2 || model.error != nil }
        XCTAssertEqual(h.packets.last, SamsungBudsCustomEqualizer.readRequest)
        h.callbacks.last?.frame(.init(command: 105, payload: Data([1, 9] + bands.map { UInt8(bitPattern: Int8($0)) }), isFragment: false))
        h.callbacks.last?.written(2); await h.until { h.packets.count == 3 || model.error != nil }
        XCTAssertEqual(h.packets.last, SamsungBudsCustomEqualizer.selectionRequest)
        h.callbacks.last?.frame(SettingsWireFixture.ack(0x86, [7]))
        XCTAssertTrue(model.busy, "ACK alone cannot confirm the custom selector")
        h.callbacks.last?.written(3); await h.until { !model.busy }
        XCTAssertNil(model.error); XCTAssertEqual(model.snapshot["custom_eq_bands"] as? [Int], bands)
        XCTAssertEqual(model.snapshot["equalizer_raw"] as? UInt8, 7)
        h.time = 12; model.perform(.refresh); await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["equalizer_raw"] as? UInt8, 7, "Retained bootstrap must preserve the verified selection")
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_010, "The selection does not renew battery age")
        model.perform(.info); await h.until { h.packets.count == 4 || model.error != nil }
        XCTAssertEqual(h.packets.last, SamsungBudsFirmwareVersion.request)
        h.callbacks.last?.frame(.init(command: 0xB4, payload: Data("R630XXU0AZG2".utf8), isFragment: false))
        h.callbacks.last?.written(4); await h.until { !model.busy }
        XCTAssertNil(model.error); XCTAssertEqual(model.snapshot["firmware_version"] as? String, "R630XXU0AZG2")
        XCTAssertTrue(h.smepOpen); model.cancel()
    }

    @MainActor func testExtendedConnectionGateRejectsMalformedQueriesAndFirmwareTransfer() async throws {
        let h = RetainedSettingsHarness()
        h.connection.handlers({ _ in }, { _ in }, { _ in })
        try await h.connection.open("AABBCCDDEEFF")
        for (command, payload): (UInt8, [UInt8]) in [(105, [1]), (0xB4, [1]), (137, [9] + Array(repeating: 11, count: 9)), (134, [8]), (0xBB, []), (0xBC, []), (0xBD, [])] {
            XCTAssertThrowsError(try h.connection.send(Packet.frame(command: command, payload: payload)))
        }
        XCTAssertTrue(h.packets.isEmpty); h.connection.reset()
    }

    func testScalarEvidenceCannotWriteMissingOffsetsAndMergesOnlyTheConfirmedField() throws {
        var e = NativeBudsSettingsEvidence()
        let generation = e.generation, owner = UUID(), date = Date(timeIntervalSince1970: 100)
        let short = Packet.Frame(command: 0x61, payload: Data(SettingsWireFixture.status().payload.prefix(25)), isFragment: false)
        e.receive(short, at: 5, date: date, generation: generation, owner: nil)
        let command = Packet.Frame(command: 139, payload: Data([1]), isFragment: false)
        XCTAssertFalse(e.arm(command, owner: owner))
        let original = SettingsWireFixture.status()
        e.receive(original, at: 6, date: date, generation: generation, owner: nil)
        XCTAssertTrue(e.arm(command, owner: owner)); e.track(11, owner: owner)
        e.receive(SettingsWireFixture.ack(139, [1]), at: 7, date: date, generation: generation, owner: owner)
        XCTAssertEqual(e.observation?.frame.payload, original.payload)
        e.written(11, generation: generation, owner: owner)
        var expected = original.payload; expected[33] = 1
        XCTAssertEqual(e.observation?.frame.payload, expected)
        XCTAssertEqual(e.observation?.date, date, "A setting confirmation must not make battery telemetry newer")
        XCTAssertTrue(e.arm(command, owner: owner)); e.track(12, owner: owner)
        e.receive(short, at: 8, date: date, generation: generation, owner: nil)
        e.receive(SettingsWireFixture.ack(139, [1]), at: 9, date: date, generation: generation, owner: owner)
        e.written(12, generation: generation, owner: owner)
        XCTAssertEqual(e.observation?.frame.payload, short.payload, "A newer shorter status cannot be indexed using a previous packet's fields")
    }

    @MainActor func testContinuityReadClosesOnlySppAndExpiresWithoutReconnecting() async {
        let h = RetainedSettingsHarness()
        let model = NativeBudsSettingsModel(environment: h.environment())
        model.releaseAfterTransaction = true
        model.select(address: "AABBCCDDEEFF", name: "Galaxy Buds3 Pro", model: "Buds3Pro", blocked: false)
        model.perform(.refresh); await h.until { !model.busy }
        XCTAssertFalse(h.open); XCTAssertTrue(h.smepOpen)
        XCTAssertEqual(h.opens, 1); XCTAssertTrue(h.packets.isEmpty)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, true)
        XCTAssertEqual(model.snapshot["connected"] as? Bool, true)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_010)
        h.time += 31
        for _ in 0..<20 {
            XCTAssertEqual(model.snapshot["can_control"] as? Bool, false)
            XCTAssertTrue(model.snapshot["connected"] is NSNull)
            XCTAssertTrue(model.snapshot["noise_mode"] is NSNull)
        }
        XCTAssertEqual(h.opens, 1, "Snapshot expiry cannot reopen the radio")
        model.cancel()
    }

    @MainActor func testContinuityWriteReopensForFreshGestureStateAndReleasesAfterExactAck() async throws {
        let h = RetainedSettingsHarness()
        let model = NativeBudsSettingsModel(environment: h.environment())
        model.releaseAfterTransaction = true
        model.select(address: "AABBCCDDEEFF", name: "Galaxy Buds3 Pro", model: "Buds3Pro", blocked: false)
        model.perform(.refresh); await h.until { !model.busy }
        let old = try XCTUnwrap(h.callbacks.last)
        h.time += 10; h.bootstrap = SettingsWireFixture.status(touch: 0xED)
        model.perform(.touch(false)); await h.until { h.packets.count == 1 }
        let expected: [UInt8] = [0, 1, 1, 0, 1, 0, 1, 1, 2, 3]
        XCTAssertEqual(Packet.decodeCompleteFrame(h.packets[0])?.payload, Data(expected))
        XCTAssertEqual(h.opens, 2, "New action must read a new physical bootstrap")
        old.frame(SettingsWireFixture.ack(0x90, expected)); old.written(h.writeID)
        XCTAssertTrue(model.busy, "An old closed stream cannot confirm a new write")
        h.callbacks.last?.frame(SettingsWireFixture.ack(0x90, expected))
        XCTAssertTrue(model.busy)
        h.callbacks.last?.written(h.writeID); await h.until { !model.busy }
        XCTAssertFalse(h.open); XCTAssertTrue(h.smepOpen)
        XCTAssertEqual(model.snapshot["touch_enabled"] as? Bool, false)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_020)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, true)
        model.cancel()
    }

    @MainActor func testParkedIdentityCannotAuthorizeWriteAfterDifferentPhysicalBootstrap() async throws {
        let h = RetainedSettingsHarness()
        let model = NativeBudsSettingsModel(environment: h.environment())
        model.releaseAfterTransaction = true
        model.select(address: "AABBCCDDEEFF", name: "Galaxy Buds3 Pro", model: "Buds3Pro", blocked: false)
        model.perform(.refresh); await h.until { !model.busy }
        let old = try XCTUnwrap(h.callbacks.last)
        var other = SettingsWireFixture.status().payload; other[14] = 0x4D
        h.bootstrap = .init(command: 0x61, payload: other, isFragment: false)
        model.perform(.equalizer(2)); await h.until { !model.busy }
        old.frame(SettingsWireFixture.status()); old.written(1)
        XCTAssertTrue(h.packets.isEmpty); XCTAssertFalse(h.open); XCTAssertTrue(h.smepOpen)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.snapshot["can_control"] as? Bool, false)
        XCTAssertTrue(model.snapshot["noise_mode"] is NSNull)
        model.cancel()
    }

    func testEvidenceMergesOnlyExactOwnedACKAndOSCompletionInEitherOrder() throws {
        for ackFirst in [false, true] {
            var e = NativeBudsSettingsEvidence()
            let owner = UUID(), generation = e.generation, date = Date(timeIntervalSince1970: 100)
            e.receive(SettingsWireFixture.status(), at: 5, date: date, generation: generation, owner: nil)
            let command = Packet.Frame(command: 0x86, payload: Data([2]), isFragment: false)
            XCTAssertTrue(e.arm(command, owner: owner)); e.track(31, owner: owner)
            e.receive(SettingsWireFixture.ack(0x86, [2]), at: 6, date: date, generation: generation, owner: UUID())
            e.written(30, generation: generation, owner: owner)
            XCTAssertEqual(e.observation?.frame.payload[9], 5)
            if ackFirst { e.receive(SettingsWireFixture.ack(0x86, [2]), at: 6, date: date, generation: generation, owner: owner) }
            e.written(31, generation: generation, owner: owner)
            if !ackFirst {
                XCTAssertEqual(e.observation?.frame.payload[9], 5)
                e.receive(SettingsWireFixture.ack(0x86, [2]), at: 6, date: date, generation: generation, owner: owner)
            }
            XCTAssertEqual(e.observation?.frame.payload[9], 2)
            XCTAssertEqual(e.observation?.date, date); XCTAssertEqual(e.observation?.monotonic, 5)
            XCTAssertEqual(e.observation?.frame.payload[7], 53)
        }
    }

    func testNoiseNotificationChangesOnlyNoiseAndNeverInventsBootstrapOrDate() throws {
        var e = NativeBudsSettingsEvidence()
        let generation = e.generation, update = Packet.Frame(command: 0x77, payload: Data([1]), isFragment: false)
        e.receive(update, at: 1, date: Date(), generation: generation, owner: nil)
        XCTAssertNil(e.observation)
        let original = SettingsWireFixture.status(), date = Date(timeIntervalSince1970: 222)
        e.receive(original, at: 2, date: date, generation: generation, owner: nil)
        e.receive(update, at: 20, date: Date(), generation: generation, owner: nil)
        var expected = original.payload; expected[12] = 1
        XCTAssertEqual(e.observation?.frame.payload, expected)
        XCTAssertEqual(e.observation?.date, date); XCTAssertEqual(e.observation?.monotonic, 2)
        e.receive(.init(command: 0x77, payload: Data([2, 99]), isFragment: false), at: 30, date: Date(), generation: generation, owner: nil)
        XCTAssertEqual(e.observation?.frame.payload, expected)
    }

    func testReleaseResetAndOldPhysicalGenerationCannotConfirmNewCommand() {
        var e = NativeBudsSettingsEvidence()
        let old = e.generation, owner = UUID(), now = Date()
        let command = Packet.Frame(command: 0x78, payload: Data([1]), isFragment: false)
        e.receive(SettingsWireFixture.status(), at: 1, date: now, generation: old, owner: nil)
        XCTAssertTrue(e.arm(command, owner: owner)); e.track(1, owner: owner)
        e.release()
        e.receive(SettingsWireFixture.ack(0x78, [1]), at: 2, date: now, generation: old, owner: owner)
        e.written(1, generation: old, owner: owner)
        XCTAssertEqual(e.observation?.frame.payload[12], 2)
        e.reset(); let current = e.generation, currentOwner = UUID()
        e.receive(SettingsWireFixture.status(), at: 3, date: now, generation: current, owner: nil)
        XCTAssertTrue(e.arm(command, owner: currentOwner)); e.track(1, owner: currentOwner)
        e.receive(SettingsWireFixture.ack(0x78, [1]), at: 4, date: now, generation: old, owner: currentOwner)
        e.written(1, generation: old, owner: currentOwner)
        XCTAssertEqual(e.observation?.frame.payload[12], 2)
        e.receive(SettingsWireFixture.ack(0x78, [1]), at: 4, date: now, generation: current, owner: currentOwner)
        e.written(1, generation: current, owner: currentOwner)
        XCTAssertEqual(e.observation?.frame.payload[12], 1)
    }

    func testConflictingNoiseEvidenceIsPreservedInsteadOfRequestedMode() {
        var e = NativeBudsSettingsEvidence()
        let owner = UUID(), generation = e.generation, date = Date()
        e.receive(SettingsWireFixture.status(), at: 1, date: date, generation: generation, owner: nil)
        XCTAssertTrue(e.arm(.init(command: 0x78, payload: Data([1]), isFragment: false), owner: owner)); e.track(1, owner: owner)
        e.receive(.init(command: 0x77, payload: Data([3]), isFragment: false), at: 2, date: date, generation: generation, owner: owner)
        e.receive(SettingsWireFixture.ack(0x78, [1]), at: 2, date: date, generation: generation, owner: owner)
        e.written(1, generation: generation, owner: owner)
        XCTAssertEqual(e.observation?.frame.payload[12], 3)
    }

    @MainActor func testPersistentRefreshAfterVerifiedWritesReplaysMergedStateWithOriginalDate() async throws {
        let h = RetainedSettingsHarness()
        let injected = NativeBudsSettingsModel(environment: h.environment())
        injected.select(address: "AA:BB:CC:DD:EE:FF", name: "Buds3 Pro de Aleph", model: nil, blocked: false)
        injected.perform(.refresh); await h.until { !injected.busy }
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(injected.batterySnapshot?.observedAt, 1_010)
        XCTAssertEqual(injected.snapshot["can_control"] as? Bool, true)
        h.time = 500 // Continuous physical session permits an aged bootstrap.
        injected.perform(.noise(.anc)); await h.until { h.packets.count == 1 }
        h.callbacks.last?.frame(SettingsWireFixture.ack(0x78, [1]))
        h.callbacks.last?.written(h.writeID); await h.until { !injected.busy }
        injected.perform(.refresh); await h.until { !injected.busy }
        XCTAssertEqual(injected.snapshot["noise_mode"] as? String, "anc")
        XCTAssertEqual(injected.snapshot["observed_at"] as? Double, 1_010)
        XCTAssertEqual(injected.batterySnapshot?.observedAt, 1_010)
        injected.perform(.equalizer(2)); await h.until { h.packets.count == 2 }
        h.callbacks.last?.written(h.writeID)
        h.callbacks.last?.frame(SettingsWireFixture.ack(0x86, [3])); await h.until { !injected.busy }
        injected.perform(.refresh); await h.until { !injected.busy }
        XCTAssertEqual(injected.snapshot["equalizer"] as? Int, 2)
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.packets.count, 2); XCTAssertEqual(h.closes, 1, "Only initial selection reset closes; transactions retain transport")
        XCTAssertTrue(h.smepOpen); XCTAssertTrue(h.open)
        injected.cancel(); XCTAssertFalse(h.open); XCTAssertTrue(h.smepOpen)
    }

    @MainActor func testIdlePeerCloseInvalidatesSnapshotAndLatePhysicalCallbacksWithoutPolling() async throws {
        let h = RetainedSettingsHarness()
        let injected = NativeBudsSettingsModel(environment: h.environment())
        injected.select(address: "AABBCCDDEEFF", name: "Galaxy Buds3 Pro", model: "Buds3Pro", blocked: false)
        injected.perform(.refresh); await h.until { !injected.busy }
        let old = try XCTUnwrap(h.callbacks.last)
        h.open = false; old.failed(.init(message: "Peer closed idle channel"))
        for _ in 0..<10 {
            XCTAssertEqual(injected.snapshot["connected"] as? Bool, false)
            XCTAssertTrue(injected.snapshot["noise_mode"] is NSNull)
            XCTAssertEqual(injected.snapshot["can_control"] as? Bool, false)
        }
        XCTAssertEqual(h.opens, 1); XCTAssertTrue(h.packets.isEmpty)
        h.time = 50; injected.perform(.refresh); await h.until { !injected.busy }
        old.frame(.init(command: 0x77, payload: Data([3]), isFragment: false)); old.written(1)
        old.failed(.init(message: "Late old physical failure"))
        injected.perform(.refresh); await h.until { !injected.busy }
        XCTAssertEqual(injected.snapshot["noise_mode"] as? String, "ambient")
        XCTAssertEqual(injected.batterySnapshot?.observedAt, 1_050)
        XCTAssertEqual(h.opens, 2); XCTAssertNil(injected.error)
        injected.cancel()
    }

    @MainActor func testMediaSwitchTraversesConnectionEvidenceAndReplaysAllConfirmedBits() async throws {
        let h = RetainedSettingsHarness(); h.bootstrap = SettingsWireFixture.status(touch: 0xED)
        let model = NativeBudsSettingsModel(environment: h.environment())
        model.select(address: "AABBCCDDEEFF", name: "Buds3 Pro de Aleph", model: nil, blocked: false)
        model.perform(.mediaControls(false)); await h.until { h.packets.count == 1 || model.error != nil }
        XCTAssertNil(model.error)
        let packet = try XCTUnwrap(h.packets.first.flatMap(Packet.decodeCompleteFrame))
        let expected: [UInt8] = [1, 0, 0, 0, 1, 0, 1, 0, 2, 3]
        XCTAssertEqual(packet.payload, Data(expected))
        h.callbacks.last?.written(h.writeID)
        h.callbacks.last?.frame(SettingsWireFixture.ack(0x90, expected)); await h.until { !model.busy }
        h.time = 12; model.perform(.refresh); await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["touch_enabled"] as? Bool, true)
        XCTAssertEqual(model.snapshot["media_controls_enabled"] as? Bool, false)
        XCTAssertEqual(model.snapshot["media_controls_mixed"] as? Bool, false)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_010)
        var replay: Packet.Frame?
        h.connection.handlers({ replay = $0 }, { _ in }, { _ in })
        try await h.connection.open("AABBCCDDEEFF")
        var expectedStatus = try XCTUnwrap(h.bootstrap?.payload); expectedStatus[10] = 0xA1
        XCTAssertEqual(replay?.payload, expectedStatus)
        XCTAssertEqual(h.opens, 1); model.cancel()
    }

    func testMediaEvidenceCannotChangeCallsOrTypesAlongWithMediaFlags() throws {
        var evidence = NativeBudsSettingsEvidence()
        let generation = evidence.generation, owner = UUID()
        evidence.receive(SettingsWireFixture.status(), at: 5, date: Date(timeIntervalSince1970: 100), generation: generation, owner: nil)
        XCTAssertFalse(evidence.arm(.init(command: 0x90, payload: Data([1, 0, 0, 0, 1, 1, 1, 0, 2, 3]), isFragment: false), owner: owner))
        XCTAssertFalse(evidence.arm(.init(command: 0x90, payload: Data([1, 0, 0, 0, 1, 0, 1, 0, 2, 4]), isFragment: false), owner: owner))
        XCTAssertTrue(evidence.arm(.init(command: 0x90, payload: Data([1, 0, 0, 0, 1, 0, 1, 0, 2, 3]), isFragment: false), owner: owner))
    }

    func testIndividualGestureEvidenceAdmitsOnlyOneSwitchAndPreservesDatedBootstrapAfterFullConfirmation() throws {
        for gesture in Packet.Gesture.allCases {
            var e = NativeBudsSettingsEvidence()
            let generation = e.generation, owner = UUID(), date = Date(timeIntervalSince1970: 100)
            let original = SettingsWireFixture.status(touch: 0xFE)
            let controls = try XCTUnwrap(Packet.status(original, model: "Buds3Pro")?.touchControls)
            let payload = controls.payload(changing: gesture, enabled: !controls.fields[gesture.rawValue]!)
            e.receive(original, at: 5, date: date, generation: generation, owner: nil)
            XCTAssertTrue(e.arm(.init(command: 0x90, payload: Data(payload), isFragment: false), owner: owner))
            e.track(1, owner: owner)
            e.receive(SettingsWireFixture.ack(0x90, payload), at: 6, date: Date(), generation: generation, owner: owner)
            XCTAssertEqual(e.observation?.frame, original)
            e.written(1, generation: generation, owner: owner)
            XCTAssertEqual(e.observation?.date, date); XCTAssertEqual(e.observation?.monotonic, 5)
            XCTAssertEqual(e.observation.flatMap { Packet.status($0.frame, model: "Buds3Pro") }?.touchControls?.fields,
                controls.replacing(with: payload)?.fields)
            XCTAssertEqual(e.observation?.frame.payload.suffix(2), original.payload.suffix(2))
        }
    }

    @MainActor func testTouchWithSwipeReplaysConfirmedMasterAndPreservesAllOtherBytesAndDate() async throws {
        let h = RetainedSettingsHarness(); h.bootstrap = SettingsWireFixture.status(touch: 0xED)
        let model = NativeBudsSettingsModel(environment: h.environment())
        model.select(address: "AABBCCDDEEFF", name: "Buds3 Pro de Aleph", model: nil, blocked: false)
        model.perform(.touch(false)); await h.until { h.packets.count == 1 }
        let expected: [UInt8] = [0, 1, 1, 0, 1, 0, 1, 1, 2, 3]
        XCTAssertEqual(Packet.decodeCompleteFrame(h.packets[0])?.payload, Data(expected))
        h.callbacks.last?.written(h.writeID)
        h.callbacks.last?.frame(SettingsWireFixture.ack(0x90, Array(expected.prefix(7))))
        XCTAssertTrue(model.busy)
        h.callbacks.last?.frame(SettingsWireFixture.ack(0x90, expected)); await h.until { !model.busy }
        h.time = 100; model.perform(.refresh); await h.until { !model.busy }
        XCTAssertEqual(model.snapshot["touch_enabled"] as? Bool, false)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1_010)
        var replay: Packet.Frame?
        h.connection.handlers({ replay = $0 }, { _ in }, { _ in })
        try await h.connection.open("AABBCCDDEEFF")
        var expectedStatus = try XCTUnwrap(h.bootstrap?.payload); expectedStatus[10] = 0x6D
        XCTAssertEqual(replay?.payload, expectedStatus)
        XCTAssertEqual(h.opens, 1); model.cancel()
    }

    @MainActor func testPhysicalMismatchOnIdleStreamRevokesControlsAndCannotReplayPriorIdentity() async {
        let h = RetainedSettingsHarness()
        let injected = NativeBudsSettingsModel(environment: h.environment())
        injected.select(address: "AABBCCDDEEFF", name: "Galaxy Buds3 Pro", model: "Buds3Pro", blocked: false)
        injected.perform(.refresh); await h.until { !injected.busy }
        var other = SettingsWireFixture.status().payload; other[14] = 0x4D
        h.callbacks.last?.frame(.init(command: 0x61, payload: other, isFragment: false))
        XCTAssertFalse(h.open); XCTAssertFalse(h.connection.continuous)
        XCTAssertEqual(injected.snapshot["can_control"] as? Bool, false)
        XCTAssertTrue(injected.snapshot["noise_mode"] is NSNull)
        XCTAssertTrue(h.packets.isEmpty); injected.cancel()
    }

    @MainActor func testCancellationResetsPhysicalGenerationBeforeSameCommandCanBeConfirmed() async {
        let h = RetainedSettingsHarness()
        let injected = NativeBudsSettingsModel(environment: h.environment())
        injected.select(address: "AABBCCDDEEFF", name: "Buds3 Pro de Aleph", model: nil, blocked: false)
        injected.perform(.noise(.anc)); await h.until { h.packets.count == 1 }
        let old = h.callbacks.last
        injected.cancel(); XCTAssertFalse(h.open)
        injected.perform(.noise(.anc)); await h.until { h.packets.count == 2 }
        old?.frame(SettingsWireFixture.ack(0x78, [1])); old?.written(2)
        h.callbacks.last?.written(1)
        XCTAssertTrue(injected.busy)
        h.callbacks.last?.frame(SettingsWireFixture.ack(0x78, [1]))
        XCTAssertTrue(injected.busy)
        h.callbacks.last?.written(2); await h.until { !injected.busy }
        XCTAssertEqual(injected.snapshot["noise_mode"] as? String, "anc")
        XCTAssertEqual(h.opens, 2); XCTAssertEqual(h.packets.count, 2)
        injected.cancel()
    }

    @MainActor func testIdleModelDeinitResetsOnlyOwnedChannelAndDoesNotReconnect() async {
        let h = RetainedSettingsHarness()
        var model: NativeBudsSettingsModel? = NativeBudsSettingsModel(environment: h.environment())
        model?.select(address: "AABBCCDDEEFF", name: "Galaxy Buds3 Pro", model: "Buds3Pro", blocked: false)
        model?.perform(.refresh); await h.until { model?.busy == false }
        weak var released = model
        model = nil
        await h.until { released == nil && !h.open }
        XCTAssertEqual(h.opens, 1); XCTAssertTrue(h.packets.isEmpty); XCTAssertTrue(h.smepOpen)
    }

    @MainActor func testNoBootstrapDoesNotCreateContinuousAuthorityOrInventStatusRequest() async throws {
        let h = RetainedSettingsHarness(); h.bootstrap = nil
        let connection = h.connection
        var frames = 0
        connection.handlers({ _ in frames += 1 }, { _ in }, { _ in })
        try await connection.open("AABBCCDDEEFF")
        try await connection.open("AABBCCDDEEFF")
        XCTAssertFalse(connection.continuous); XCTAssertNil(connection.observation)
        XCTAssertEqual(frames, 0); XCTAssertEqual(h.opens, 1); XCTAssertTrue(h.packets.isEmpty)
        XCTAssertThrowsError(try connection.send(Packet.frame(command: 0x78, payload: [1])))
        connection.reset()
    }

    @MainActor func testOneOwnedWriteAtATimeAndNoSyntheticStatusRequests() async throws {
        let h = RetainedSettingsHarness()
        let connection = h.connection
        connection.handlers({ _ in }, { _ in }, { _ in })
        try await connection.open("AABBCCDDEEFF")
        let packet = Packet.frame(command: 0x86, payload: [1])
        _ = try connection.send(packet)
        XCTAssertThrowsError(try connection.send(packet))
        XCTAssertEqual(h.packets.count, 1)
        connection.releaseTransaction()
        connection.handlers({ _ in }, { _ in }, { _ in })
        try await connection.open("AABBCCDDEEFF")
        XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.packets.count, 1)
        connection.reset()
    }
}
