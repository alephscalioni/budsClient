import XCTest
@testable import BudsAutoSwitch

private enum CustomEQFixture {
    static let bands = [-10, -5, -1, 0, 1, 5, 10, 0, -10]
    static let version = "R630XXU0AXF3"

    // Hand-shaped original decoder layout. A non-flat table catches incorrect
    // offsets, including treating the omitted flat preset as a wire row.
    static func curve(_ bands: [Int] = CustomEQFixture.bands, presets: Int = 6) -> SamsungBudsSettingsPacket.Frame {
        let table = Array(repeating: UInt8(3), count: (presets - 1) * 9)
        return .init(command: 105, payload: Data([UInt8(presets), 9] + table
            + bands.map { UInt8(bitPattern: Int8($0)) }), isFragment: false)
    }
    static func firmware(_ version: String = CustomEQFixture.version) -> SamsungBudsSettingsPacket.Frame {
        .init(command: 0xB4, payload: Data(version.utf8), isFragment: false)
    }
    static func status(equalizer: UInt8 = 5, physical: Bool? = true) -> SamsungBudsSettingsPacket.Frame {
        var bytes = SettingsWireFixture.status(equalizer: equalizer).payload
        bytes[25] = 16; bytes[26] = 1; bytes[27] = 2; bytes[28] = 1; bytes[33] = 1
        if physical != true {
            // 0x0155 is a valid Buds3 Pro color (341); use 342 for a foreign model.
            bytes[14] = physical == false ? 0x56 : 0; bytes[15] = physical == false ? 1 : 0
            bytes[16] = bytes[14]; bytes[17] = bytes[15]
        }
        return .init(command: 0x61, payload: bytes, isFragment: false)
    }
}

/// Entirely injected SDK, connection and clock. No radio, audio, processes,
/// production timers, firmware transfer or Find operations are constructed.
@MainActor private final class CustomEQHarness {
    typealias Packet = SamsungBudsSettingsPacket
    struct Callbacks {
        let receive: (Packet.Frame) -> Void
        let written: (UInt) -> Void
        let failed: (NativeBudsError) -> Void
    }
    var time: TimeInterval = 0
    var wallOffset: TimeInterval = 0
    var alive = true
    var connected = true
    var continuous = false
    var pendingOperations = 0
    var checks = 0
    var opens = 0
    var packets: [Data] = []
    var status: Packet.Frame? = CustomEQFixture.status()
    var statusStamp: (TimeInterval, Date)?
    var callbacks: Callbacks?
    var sessions: [Callbacks] = []
    var onOpen: ((Int) -> Void)?
    var holdOpen = false
    var bootstrapBeforeAlive = false
    var openGate: CheckedContinuation<Void, Never>?
    var ignoreSleepCancellation = false
    var expiredSleepHook: ((TimeInterval) async -> Void)?
    private var sleepers: [UUID: (TimeInterval, TimeInterval, CheckedContinuation<Void, Error>)] = [:]

    func environment() -> NativeBudsSettingsEnvironment {
        .init(now: { self.time }, date: { Date(timeIntervalSince1970: 1_000 + self.time + self.wallOffset) },
            sleep: { try await self.sleep($0) }, connected: { _ in self.checks += 1; return self.connected },
            handlers: { receive, written, failed in
                if let receive, let written, let failed {
                    let callbacks = Callbacks(receive: receive, written: written, failed: failed)
                    self.callbacks = callbacks; self.sessions.append(callbacks)
                } else { self.callbacks = nil }
            }, open: { _ in
                self.opens += 1
                if self.holdOpen { await withCheckedContinuation { self.openGate = $0 } }
                if self.bootstrapBeforeAlive { self.alive = false }
                if let status = self.status { self.callbacks?.receive(status) }
                if self.bootstrapBeforeAlive { self.alive = true }
                self.onOpen?(self.opens)
            }, send: { self.packets.append($0); return UInt(self.packets.count) }, close: {},
            statusTimestamp: { self.statusStamp }, continuousStatus: { self.continuous },
            sessionAlive: { self.alive }, diagnostics: { ["pending_operations": self.pendingOperations] })
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            if !ignoreSleepCancellation { try Task.checkCancellation() }
            try await withCheckedThrowingContinuation { sleepers[id] = (time + seconds, seconds, $0) }
            if let hook = expiredSleepHook { await hook(seconds) }
        } onCancel: {
            Task { @MainActor in
                if !self.ignoreSleepCancellation {
                    self.sleepers.removeValue(forKey: id)?.2.resume(throwing: CancellationError())
                }
            }
        }
    }
    var responseWaiting: Bool { sleepers.values.contains { $0.0 == time + 5 } }
    func advance(_ seconds: TimeInterval) {
        time += seconds
        let due = sleepers.filter { $0.value.0 <= time }.map(\.key)
        for id in due { sleepers.removeValue(forKey: id)?.2.resume() }
    }
    func drainSleepers() {
        let pending = sleepers; sleepers = [:]
        for value in pending.values { value.2.resume(throwing: CancellationError()) }
    }
    func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<500 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Injected operation did not reach the expected state", file: file, line: line)
    }
    func settle() async { for _ in 0..<20 { await Task.yield() } }
    func select(_ model: NativeBudsSettingsModel, address: String = "AA:BB:CC:DD:EE:FF",
                modelName: String? = "Buds3Pro", epoch: UUID? = nil) {
        model.select(address: address, name: "Galaxy Buds3 Pro", model: modelName, blocked: false, connectionEpoch: epoch)
    }
    var commands: [UInt8] { packets.compactMap { Packet.decodeCompleteFrame($0)?.command } }
}

final class NativeBudsCustomEqualizerTests: XCTestCase {
    typealias EQ = SamsungBudsCustomEqualizer
    typealias Version = SamsungBudsFirmwareVersion
    typealias Packet = SamsungBudsSettingsPacket
    typealias Model = NativeBudsSettingsModel

    @MainActor func testHelperBootstrapCanPrecedeOpenCompletionButReplyStillNeedsLiveSession() async {
        for action in [Model.Action.customEqualizerRead, .info] {
            let h = CustomEQHarness(); h.bootstrapBeforeAlive = true
            let model = Model(environment: h.environment()); h.select(model)
            model.perform(action); await h.until { h.packets.count == 1 }
            XCTAssertNil(model.error)
            if action == .info { h.callbacks?.receive(CustomEQFixture.firmware()) }
            else { h.callbacks?.receive(CustomEQFixture.curve()) }
            h.callbacks?.written(1); await h.until { !model.busy }
            XCTAssertNil(model.error)
            if action == .info { XCTAssertEqual(model.snapshot["firmware_version"] as? String, CustomEQFixture.version) }
            else { XCTAssertEqual(model.snapshot["custom_eq_bands"] as? [Int], CustomEQFixture.bands) }
            model.cancel()
        }
        let h = CustomEQHarness(); h.bootstrapBeforeAlive = true
        let model = Model(environment: h.environment()); h.select(model)
        model.perform(.customEqualizerRead); await h.until { h.packets.count == 1 }
        h.alive = false; h.callbacks?.receive(CustomEQFixture.curve())
        await h.until { !model.busy }
        XCTAssertNotNil(model.error); XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
        model.cancel()
    }

    func testExactOriginalRequestBytesAndSignedGains() throws {
        // Independent CRC-CCITT-zero reference vectors (not encoder round trips).
        XCTAssertEqual(EQ.readRequest, Data([0xFD, 3, 0, 0x69, 0x8F, 0xFD, 0xDD]))
        XCTAssertEqual(Version.request, Data([0xFD, 3, 0, 0xB4, 0x5F, 0xE7, 0xDD]))
        XCTAssertEqual(EQ.selectionRequest, Data([0xFD, 4, 0, 0x86, 7, 0xD9, 0xC1, 0xDD]))
        XCTAssertEqual(EQ.writeRequest(CustomEQFixture.bands), Data([
            0xFD, 0x0D, 0, 0x89, 9, 0xF6, 0xFB, 0xFF, 0, 1, 5, 10, 0, 0xF6, 0xDD, 0xF8, 0xDD
        ]))
        for bands in [[], Array(repeating: 0, count: 8), Array(repeating: 0, count: 10),
                      [-11] + Array(repeating: 0, count: 8), [11] + Array(repeating: 0, count: 8),
                      [Int.min] + Array(repeating: 0, count: 8), [Int.max] + Array(repeating: 0, count: 8)] {
            XCTAssertNil(EQ.writeRequest(bands))
        }
    }

    func testCustomReplyUsesOmittedFlatTableAndRejectsEveryWrongShape() throws {
        for count in 1...7 {
            let frame = CustomEQFixture.curve(presets: count)
            XCTAssertEqual(EQ.curve(frame), EQ.Curve(presetCount: count, bands: CustomEQFixture.bands))
            for length in 0..<frame.payload.count {
                XCTAssertNil(EQ.curve(.init(command: 105, payload: Data(frame.payload.prefix(length)), isFragment: false)))
            }
            XCTAssertNil(EQ.curve(.init(command: 105, payload: frame.payload + Data([0]), isFragment: false)))
        }
        let valid = CustomEQFixture.curve()
        for header: [UInt8] in [[0, 9], [8, 9], [255, 9], [6, 0], [6, 8], [6, 10], [255, 255]] {
            var bytes = valid.payload; bytes.replaceSubrange(0..<2, with: header)
            XCTAssertNil(EQ.curve(.init(command: 105, payload: bytes, isFragment: false)))
        }
        for byte: UInt8 in [11, 127, 128, 245] {
            for index in [2, valid.payload.count - 1] {
                var bytes = valid.payload; bytes[index] = byte
                XCTAssertNil(EQ.curve(.init(command: 105, payload: bytes, isFragment: false)))
            }
        }
        XCTAssertNil(EQ.curve(.init(command: 105, payload: Data(repeating: 0, count: 4096), isFragment: false)))
        XCTAssertNil(EQ.curve(.init(command: 137, payload: valid.payload, isFragment: false)))
        XCTAssertNil(EQ.curve(.init(command: 105, payload: valid.payload, isFragment: true)))
        var prefix = Data([99, 99]); prefix.append(valid.payload)
        XCTAssertEqual(EQ.curve(.init(command: 105, payload: prefix.dropFirst(2), isFragment: false))?.bands, CustomEQFixture.bands)
        XCTAssertEqual(EQ.curve(CustomEQFixture.curve(Array(repeating: 0, count: 9)))?.bands, Array(repeating: 0, count: 9),
            "An actual complete flat reply is valid; a decoder fallback is not")
    }

    @MainActor func testStrictBandsJSONParserAndDirectActionValidation() throws {
        let good = "{\"action\":\"device.custom_eq\",\"bands\":[-10,-5,-1,0,1,5,10,0,-10]}"
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(good.utf8)) as? [String: Any])
        XCTAssertEqual(Model.Action.parse(request), .customEqualizer(CustomEQFixture.bands))
        XCTAssertEqual(Model.Action.parse(["action": "device.custom_eq_read"]), .customEqualizerRead)
        XCTAssertEqual(Model.Action.parse(["action": "device.info"]), .info)
        XCTAssertNil(Model.Action.parse(["action": "device.custom_eq"]))
        for invalid: Any in [true, false, "1", NSNull(), [1], ["value": 1], 0.5, 10.01,
                              -11, 11, Double.nan, Double.infinity, -Double.infinity, Int.min, Int.max, UInt64.max] {
            let values: [Any] = [invalid] + Array(repeating: 0, count: 8)
            XCTAssertNil(Model.Action.parse(["action": "device.custom_eq", "bands": values]), "\(invalid)")
        }
        for invalid: Any in ["0,0,0,0,0,0,0,0,0", NSNull(), 9, [Int](), Array(repeating: 0, count: 8), Array(repeating: 0, count: 10)] {
            XCTAssertNil(Model.Action.parse(["action": "device.custom_eq", "bands": invalid]))
        }
        let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
        defer { model.cancel() }
        for bands in [[], Array(repeating: 0, count: 8), [11] + Array(repeating: 0, count: 8)] {
            model.perform(.customEqualizer(bands)); XCTAssertFalse(model.busy); XCTAssertNotNil(model.error)
        }
        model.perform(.equalizer(6))
        XCTAssertEqual(h.checks, 0); XCTAssertEqual(h.opens, 0); XCTAssertTrue(h.packets.isEmpty)
        XCTAssertNil(Model.Action.parse(["action": "device.equalizer", "preset": 6]))
        XCTAssertNil(Model.Action.parse(["action": "device.equalizer", "preset": 7]))
    }

    func testFirmwareIdentityIsStrictWholeASCIIAndReadOnly() {
        XCTAssertEqual(Version.version(CustomEQFixture.firmware()), CustomEQFixture.version)
        for text in ["", "R630", "R630XXU0AXF", "R630XXU0AXF30", "R640XXU0AXF3", "R540XXU0AXF3",
                     "r630XXU0AXF3", "R630xxU0AXF3", "R630XXU0AXF ", "R630XXU0AXF\n", "R630XXU0AXF\0", "R630XXU0AXFé"] {
            XCTAssertNil(Version.version(CustomEQFixture.firmware(text)), text)
        }
        var bytes = CustomEQFixture.firmware().payload; bytes[11] = 0xFF
        XCTAssertNil(Version.version(.init(command: 0xB4, payload: bytes, isFragment: false)))
        XCTAssertNil(Version.version(.init(command: 0xB4, payload: CustomEQFixture.firmware().payload, isFragment: true)))
        XCTAssertNil(Version.version(.init(command: 0x63, payload: CustomEQFixture.firmware().payload, isFragment: false)))
        XCTAssertTrue(Version.permits(.init(command: 0xB4, payload: Data(), isFragment: false)))
        for command: UInt8 in [0xB4, 0xB5, 0xB6, 0xB7, 0xB8] {
            XCTAssertFalse(Version.permits(.init(command: command, payload: Data([0]), isFragment: false)))
        }
        XCTAssertFalse(Version.permits(.init(command: 0xB5, payload: Data(), isFragment: false)))
    }

    func testCustomSelectionACKIsExactAndDoesNotWidenBasePresetAPI() {
        XCTAssertTrue(EQ.acknowledgesSelection(SettingsWireFixture.ack(134, [7])))
        for frame in [SettingsWireFixture.ack(134, []), SettingsWireFixture.ack(134, [6]),
                      SettingsWireFixture.ack(134, [7, 0]), SettingsWireFixture.ack(137, [7]),
                      Packet.Frame(command: 134, payload: Data([7]), isFragment: false),
                      Packet.Frame(command: 0x42, payload: Data([134, 7]), isFragment: true)] {
            XCTAssertFalse(EQ.acknowledgesSelection(frame))
        }
        XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(134, [7]), command: 134, payload: [7]))
        for data in [EQ.readRequest, EQ.selectionRequest, EQ.writeRequest(CustomEQFixture.bands)!] {
            XCTAssertTrue(EQ.permits(Packet.decodeCompleteFrame(data)!))
        }
        for frame in [Packet.Frame(command: 105, payload: Data([0]), isFragment: false),
                      .init(command: 137, payload: Data([9] + Array(repeating: 11, count: 9)), isFragment: false),
                      .init(command: 137, payload: Data([8] + Array(repeating: 0, count: 8)), isFragment: false),
                      .init(command: 134, payload: Data([6]), isFragment: false),
                      .init(command: 105, payload: Data(), isFragment: true)] {
            XCTAssertFalse(EQ.permits(frame))
        }
    }

    @MainActor func testExplicitReadWaitsForActualCurveAndSDKInEitherOrderWithoutSelecting() async throws {
        for replyFirst in [true, false] {
            let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
            defer { model.cancel() }
            XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
            XCTAssertTrue(model.snapshot["custom_eq_observed_at"] is NSNull)
            XCTAssertEqual(model.snapshot["can_custom_eq_read"] as? Bool, false)
            model.perform(["action": "device.custom_eq_read"])
            await h.until { h.packets.count == 1 && h.responseWaiting }
            let callback = try XCTUnwrap(h.callbacks)
            XCTAssertEqual(h.commands, [105])
            callback.receive(.init(command: 105, payload: Data([6, 9]), isFragment: false))
            callback.receive(CustomEQFixture.firmware())
            callback.receive(SettingsWireFixture.ack(105, []))
            if replyFirst { h.time = 1; callback.receive(CustomEQFixture.curve()) }
            else { callback.written(1) }
            await h.settle()
            XCTAssertTrue(model.busy); XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
            if replyFirst { h.time = 2; callback.written(1) }
            else { h.time = 1; callback.receive(CustomEQFixture.curve()) }
            await h.until { !model.busy }
            XCTAssertNil(model.error)
            XCTAssertEqual(model.snapshot["custom_eq_bands"] as? [Int], CustomEQFixture.bands)
            XCTAssertEqual(model.snapshot["custom_eq_observed_at"] as? Double, 1_001)
            XCTAssertEqual(model.snapshot["can_custom_eq_read"] as? Bool, true)
            XCTAssertEqual(model.snapshot["can_custom_eq_write"] as? Bool, true)
            XCTAssertEqual(model.snapshot["equalizer"] as? Int, 4)
            XCTAssertEqual(h.commands, [105]); XCTAssertTrue(model.snapshot["firmware_version"] is NSNull)
        }
    }

    @MainActor func testWriteNeeds137SDKThenFreshMatching105AndItsSDKThenExact7ACKAndSDK() async throws {
        let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
        defer { model.cancel() }
        model.perform(.customEqualizer(CustomEQFixture.bands))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        let callback = try XCTUnwrap(h.callbacks)
        let before = model.snapshot
        XCTAssertEqual(h.commands, [137])
        callback.receive(CustomEQFixture.curve()) // Unsolicited/pre-query curve is not readback.
        callback.receive(SettingsWireFixture.ack(137, Array(h.packets[0])))
        callback.written(999)
        await h.settle(); XCTAssertEqual(h.commands, [137])
        callback.written(1)
        await h.until { h.packets.count == 2 && h.responseWaiting }
        XCTAssertEqual(h.commands, [137, 105])
        callback.written(1) // Stale completion from the preceding step.
        h.time = 1; callback.receive(CustomEQFixture.curve())
        await h.settle()
        XCTAssertEqual(h.commands, [137, 105]); XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
        callback.written(2)
        await h.until { h.packets.count == 3 && h.responseWaiting }
        XCTAssertEqual(h.commands, [137, 105, 134])
        XCTAssertEqual(h.packets[2], EQ.selectionRequest)
        XCTAssertEqual(model.snapshot["custom_eq_bands"] as? [Int], CustomEQFixture.bands)
        XCTAssertEqual(model.snapshot["equalizer"] as? Int, 4)
        callback.receive(SettingsWireFixture.ack(134, [6]))
        callback.receive(SettingsWireFixture.ack(134, [7, 0]))
        callback.written(2)
        callback.receive(SettingsWireFixture.ack(134, [7]))
        await h.settle(); XCTAssertTrue(model.busy)
        callback.written(3)
        await h.until { !model.busy }
        XCTAssertNil(model.error)
        let after = model.snapshot
        XCTAssertTrue(after["equalizer"] is NSNull, "Custom must never be reported as preset 0...5")
        XCTAssertEqual(after["equalizer_raw"] as? UInt8, 7)
        XCTAssertEqual(after["equalizer_enabled"] as? Bool, true)
        XCTAssertEqual(after["equalizer_custom"] as? Bool, true)
        XCTAssertEqual(after["custom_eq_observed_at"] as? Double, 1_001)
        for key in ["settings", "noise_mode", "ambient_level", "touch_enabled", "touch_controls", "media_controls_enabled", "observed_at"] {
            XCTAssertEqual(try XCTUnwrap(after[key] as? NSObject), try XCTUnwrap(before[key] as? NSObject), key)
        }
        XCTAssertEqual((after["settings"] as? [String: Any])?["stereo_balance"] as? Int, 16)
        XCTAssertEqual(h.commands, [137, 105, 134])
    }

    @MainActor func testMismatchedReadbackPublishesOnlyRealCurveAndNeverSelectsCustom() async throws {
        let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
        defer { model.cancel() }
        model.perform(.customEqualizer(CustomEQFixture.bands))
        await h.until { h.packets.count == 1 }
        h.callbacks?.written(1); await h.until { h.packets.count == 2 && h.responseWaiting }
        let actual = Array(repeating: 0, count: 9)
        h.callbacks?.receive(CustomEQFixture.curve(actual)); h.callbacks?.written(2)
        await h.until { !model.busy }
        XCTAssertNotNil(model.error); XCTAssertTrue(model.error?.contains("diverge") == true)
        XCTAssertEqual(h.commands, [137, 105])
        XCTAssertEqual(model.snapshot["custom_eq_bands"] as? [Int], actual)
        XCTAssertEqual(model.snapshot["custom_eq_observed_at"] as? Double, 1_000)
        XCTAssertEqual(model.snapshot["can_custom_eq_write"] as? Bool, false)
        XCTAssertTrue(model.snapshot["equalizer_custom"] is NSNull)
    }

    @MainActor func testNoCustomReadOrWriteSuccessFromOnlySentACKOrSDK() async {
        for action in [Model.Action.customEqualizerRead, .customEqualizer(CustomEQFixture.bands)] {
            let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
            model.perform(action); await h.until { h.packets.count == 1 && h.responseWaiting }
            if action != .customEqualizerRead {
                h.callbacks?.written(1); await h.until { h.packets.count == 2 && h.responseWaiting }
            }
            h.callbacks?.written(UInt(h.packets.count))
            h.callbacks?.receive(SettingsWireFixture.ack(105, []))
            h.callbacks?.receive(.init(command: 105, payload: Data([6, 9]), isFragment: false))
            await h.settle(); XCTAssertTrue(model.busy)
            h.advance(5); await h.until { !model.busy }
            XCTAssertNotNil(model.error); XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
            XCTAssertFalse(h.commands.contains(134)); model.cancel()
        }
    }

    @MainActor func testExplicitFirmwareReadRequiresFreshReplyAndSDKInEitherOrderAndKeepsActualDate() async throws {
        for replyFirst in [true, false] {
            let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
            defer { model.cancel() }
            model.perform(.info); await h.until { h.packets.count == 1 && h.responseWaiting }
            let callback = try XCTUnwrap(h.callbacks)
            XCTAssertEqual(h.packets, [Version.request])
            if replyFirst { h.time = 1; callback.receive(CustomEQFixture.firmware()) }
            else { callback.written(1) }
            await h.settle(); XCTAssertTrue(model.busy); XCTAssertTrue(model.snapshot["firmware_version"] is NSNull)
            if replyFirst { h.time = 2; callback.written(1) }
            else { h.time = 1; callback.receive(CustomEQFixture.firmware()) }
            await h.until { !model.busy }
            XCTAssertNil(model.error)
            XCTAssertEqual(model.snapshot["firmware_version"] as? String, CustomEQFixture.version)
            XCTAssertEqual(model.snapshot["firmware_observed_at"] as? Double, 1_001)
            XCTAssertEqual(model.snapshot["observed_at"] as? Double, 1_000)
            XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
            XCTAssertEqual(h.commands, [0xB4])
            model.cancel()
            XCTAssertEqual(model.snapshot["firmware_observed_at"] as? Double, 1_001, "Cancellation cannot redate a historical actual reply")
            XCTAssertEqual(model.snapshot["can_info"] as? Bool, false)
        }
    }

    @MainActor func testFirmwareNeverSucceedsFromSDKACKOtherModelMalformedFragmentOrPreQueryReply() async {
        for missing in ["reply", "sdk"] {
            let h = CustomEQHarness()
            h.onOpen = { _ in h.callbacks?.receive(CustomEQFixture.firmware()) }
            let model = Model(environment: h.environment()); h.select(model)
            model.perform(.info); await h.until { h.packets.count == 1 && h.responseWaiting }
            if missing == "sdk" { h.callbacks?.receive(CustomEQFixture.firmware()) }
            else {
                h.callbacks?.written(1)
                for frame in [SettingsWireFixture.ack(0xB4, []), CustomEQFixture.firmware("R640XXU0AXF3"),
                              CustomEQFixture.firmware("R630XXU0AXF3\0"),
                              Packet.Frame(command: 0xB4, payload: CustomEQFixture.firmware().payload, isFragment: true),
                              Packet.Frame(command: 0x63, payload: CustomEQFixture.firmware().payload, isFragment: false)] {
                    h.callbacks?.receive(frame)
                }
            }
            await h.settle(); XCTAssertTrue(model.busy); XCTAssertTrue(model.snapshot["firmware_version"] is NSNull)
            h.advance(5); await h.until { !model.busy }
            XCTAssertNotNil(model.error); XCTAssertTrue(model.snapshot["firmware_version"] is NSNull)
            XCTAssertTrue(model.snapshot["firmware_observed_at"] is NSNull)
            XCTAssertEqual(h.commands, [0xB4]); model.cancel()
        }
    }

    @MainActor func testRawDisabledCustomAndUnknownEQDoNotFalsifyPresetAPI() async {
        for raw: UInt8 in [0, 1, 6, 7, 8, 255] {
            let h = CustomEQHarness(); h.status = CustomEQFixture.status(equalizer: raw)
            let model = Model(environment: h.environment()); h.select(model)
            model.perform(.refresh); await h.until { !model.busy }
            XCTAssertEqual(model.snapshot["equalizer_raw"] as? UInt8, raw)
            XCTAssertEqual(model.snapshot["equalizer_enabled"] as? Bool, raw != 0)
            XCTAssertEqual(model.snapshot["equalizer_custom"] as? Bool, raw == 7)
            if (1...6).contains(raw) { XCTAssertEqual(model.snapshot["equalizer"] as? Int, Int(raw) - 1) }
            else { XCTAssertTrue(model.snapshot["equalizer"] is NSNull) }
            XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
            XCTAssertTrue(model.snapshot["firmware_version"] is NSNull)
            XCTAssertTrue(h.packets.isEmpty, "Refresh must not issue custom or firmware background queries")
            model.cancel()
        }
    }

    @MainActor func testFreshVerifiedIdentityIsRequiredAndOtherModelsNeverReachTransport() async {
        let actions: [Model.Action] = [.customEqualizerRead, .customEqualizer(CustomEQFixture.bands), .info]
        for action in actions {
            for name in ["BudsPro", "Buds2Pro", "Buds3", "Buds3Fe", "Buds4", "Buds4Pro"] {
                let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model, modelName: name)
                model.perform(action)
                await h.until { !model.busy }
                XCTAssertNotNil(model.error, "A different physical bootstrap must reject the selected model")
                XCTAssertTrue(h.packets.isEmpty); model.cancel()
            }
            for physical: Bool? in [false, nil] {
                let h = CustomEQHarness(); h.status = CustomEQFixture.status(physical: physical)
                let model = Model(environment: h.environment()); h.select(model)
                model.perform(action); await h.until { !model.busy }
                XCTAssertNotNil(model.error); XCTAssertTrue(h.packets.isEmpty); model.cancel()
            }
            for age in [-1.0, 16.0] {
                let h = CustomEQHarness(); h.time = 20; h.continuous = true
                h.statusStamp = (20 - age, Date(timeIntervalSince1970: 1_020 - age))
                let model = Model(environment: h.environment()); h.select(model)
                model.perform(action); await h.until { !model.busy }
                XCTAssertNotNil(model.error); XCTAssertTrue(h.packets.isEmpty, "Continuous stream cannot bypass the new actions' freshness bound")
                model.cancel()
            }
        }
    }

    @MainActor func testChangedPhysicalModelAtCommandOpenOrWhileWaitingFailsClosed() async {
        for action in [Model.Action.customEqualizerRead, .customEqualizer(CustomEQFixture.bands), .info] {
            for duringOpen in [true, false] {
                let h = CustomEQHarness()
                h.onOpen = { count in
                    if duringOpen && count == 2 { h.callbacks?.receive(CustomEQFixture.status(physical: false)) }
                }
                let model = Model(environment: h.environment()); h.select(model)
                model.perform(action)
                if !duringOpen {
                    await h.until { h.packets.count == 1 && h.responseWaiting }
                    h.callbacks?.receive(CustomEQFixture.status(physical: false))
                }
                await h.until { !model.busy }
                XCTAssertNotNil(model.error); XCTAssertEqual(h.packets.count, duringOpen ? 0 : 1)
                XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
                XCTAssertTrue(model.snapshot["firmware_version"] is NSNull); model.cancel()
            }
        }
    }

    @MainActor func testCancellationSelectionAndConnectionEpochFenceOldRepliesSDKAndTimers() async throws {
        for change in ["cancel", "address", "epoch", "model"] {
            let h = CustomEQHarness(); h.ignoreSleepCancellation = true
            let model = Model(environment: h.environment()); let epoch = UUID(); h.select(model, epoch: epoch)
            defer { model.cancel(); h.drainSleepers() }
            model.perform(.info); await h.until { h.packets.count == 1 && h.responseWaiting }
            let old = try XCTUnwrap(h.callbacks)
            switch change {
            case "address": h.select(model, address: "11:22:33:44:55:66", epoch: epoch)
            case "epoch": h.select(model, epoch: UUID())
            case "model": h.select(model, modelName: "Buds4Pro", epoch: epoch)
            default: model.cancel()
            }
            old.receive(CustomEQFixture.firmware()); old.written(1)
            XCTAssertTrue(model.snapshot["firmware_version"] is NSNull)
            if change == "model" { continue }
            h.time = 1
            model.perform(.customEqualizerRead); await h.until { h.packets.count == 2 && h.responseWaiting }
            old.receive(CustomEQFixture.curve()); old.written(2); old.failed(.init(message: "Late failure"))
            // The retired response timer ignores cancellation at the effect
            // boundary. Its generation/session/wait identities must still fence it.
            h.advance(4); await h.settle()
            XCTAssertTrue(model.busy); XCTAssertNil(model.error)
            XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
            h.callbacks?.receive(CustomEQFixture.curve()); h.callbacks?.written(2)
            await h.until { !model.busy }
            XCTAssertNil(model.error); XCTAssertEqual(model.snapshot["custom_eq_bands"] as? [Int], CustomEQFixture.bands)
            XCTAssertTrue(model.snapshot["firmware_version"] is NSNull)
            h.advance(30); await h.settle(); XCTAssertNil(model.error)
            XCTAssertEqual(h.commands, [0xB4, 105])
        }
    }

    @MainActor func testCancelledOpenCannotSendAfterSelectionChanges() async {
        let h = CustomEQHarness(); h.holdOpen = true
        let model = Model(environment: h.environment()); h.select(model)
        defer { model.cancel() }
        model.perform(.customEqualizer(CustomEQFixture.bands))
        await h.until { h.openGate != nil }
        h.select(model, address: "11:22:33:44:55:66")
        h.openGate?.resume(); h.openGate = nil
        await h.settle()
        XCTAssertFalse(model.busy); XCTAssertTrue(h.packets.isEmpty)
        XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
    }

    @MainActor func testCancellationAtEveryCustomStepFencesLateSDKReadbackAndACK() async throws {
        for step in 1...3 {
            for changeSelection in [false, true] {
                let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
                defer { model.cancel() }
                model.perform(.customEqualizer(CustomEQFixture.bands))
                await h.until { h.packets.count == 1 && h.responseWaiting }
                if step >= 2 {
                    h.callbacks?.written(1); await h.until { h.packets.count == 2 && h.responseWaiting }
                }
                if step == 3 {
                    h.callbacks?.receive(CustomEQFixture.curve()); h.callbacks?.written(2)
                    await h.until { h.packets.count == 3 && h.responseWaiting }
                }
                let old = try XCTUnwrap(h.callbacks)
                if changeSelection { h.select(model, address: "11:22:33:44:55:66") }
                else { model.cancel() }
                old.written(UInt(step)); old.receive(CustomEQFixture.curve())
                old.receive(SettingsWireFixture.ack(134, [7])); old.written(3)
                h.advance(30); await h.settle()
                XCTAssertFalse(model.busy); XCTAssertEqual(h.packets.count, step)
                XCTAssertTrue(model.snapshot["equalizer_custom"] is NSNull)
                XCTAssertEqual(model.snapshot["can_custom_eq_write"] as? Bool, false)
                if step < 3 || changeSelection { XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull) }
                else { XCTAssertEqual(model.snapshot["custom_eq_bands"] as? [Int], CustomEQFixture.bands) }
            }
        }
    }

    @MainActor func testExpiredReadbackTimerCannotAbortTheNextSelectionACKWait() async throws {
        let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
        var advanced = false
        h.expiredSleepHook = { seconds in
            guard seconds == 5, !advanced else { return }
            advanced = true
            // The timeout effect has returned as the real reply and SDK event
            // advance this same operation to a different response wait.
            h.callbacks?.receive(CustomEQFixture.curve()); h.callbacks?.written(2)
            await h.until { h.packets.count == 3 && h.responseWaiting }
        }
        defer { model.cancel(); h.expiredSleepHook = nil }
        model.perform(.customEqualizer(CustomEQFixture.bands))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        h.callbacks?.written(1); await h.until { h.packets.count == 2 && h.responseWaiting }
        await h.settle()
        h.advance(5)
        await h.until { h.packets.count == 3 && h.responseWaiting }
        await h.settle()
        XCTAssertTrue(advanced); XCTAssertTrue(model.busy); XCTAssertNil(model.error)
        h.callbacks?.receive(SettingsWireFixture.ack(134, [7])); h.callbacks?.written(3)
        await h.until { !model.busy }
        XCTAssertNil(model.error); XCTAssertEqual(model.snapshot["equalizer_custom"] as? Bool, true)
    }

    @MainActor func testLateSDKCannotPublishAfterResponseDeadlineEvenWhenSleepHasNotFired() async throws {
        for action in [Model.Action.customEqualizerRead, .info] {
            let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
            defer { model.cancel() }
            model.perform(action); await h.until { h.packets.count == 1 && h.responseWaiting }
            if action == .info { h.callbacks?.receive(CustomEQFixture.firmware()) }
            else { h.callbacks?.receive(CustomEQFixture.curve()) }
            // Clock moves without resuming the timer, as with a stalled timer
            // effect. A late SDK event still cannot turn this into success.
            h.time = 6; h.callbacks?.written(1)
            await h.until { !model.busy }
            XCTAssertNotNil(model.error); XCTAssertTrue(model.snapshot["firmware_version"] is NSNull)
            XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
        }
    }

    @MainActor func testContradictoryRepliesCannotChooseWhicheverCurveOrVersionMatches() async {
        for action in [Model.Action.customEqualizerRead, .info] {
            let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
            defer { model.cancel() }
            model.perform(action); await h.until { h.packets.count == 1 && h.responseWaiting }
            if action == .info {
                h.callbacks?.receive(CustomEQFixture.firmware())
                h.callbacks?.receive(CustomEQFixture.firmware("R630XXU0AXF4"))
            } else {
                h.callbacks?.receive(CustomEQFixture.curve())
                h.callbacks?.receive(CustomEQFixture.curve(Array(repeating: 0, count: 9)))
            }
            await h.until { !model.busy }
            XCTAssertNotNil(model.error)
            XCTAssertTrue(model.snapshot["firmware_version"] is NSNull)
            XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull)
            XCTAssertEqual(h.packets.count, 1)
        }
    }

    @MainActor func testActualReadingsStayWithSelectedDeviceAndClearOnConnectionLoss() async {
        for change in ["address", "epoch", "model", "disconnect"] {
            let h = CustomEQHarness(); let model = Model(environment: h.environment()); let epoch = UUID()
            h.select(model, epoch: epoch)
            model.perform(.customEqualizerRead); await h.until { h.packets.count == 1 }
            h.callbacks?.receive(CustomEQFixture.curve()); h.callbacks?.written(1)
            await h.until { !model.busy }
            model.perform(.info); await h.until { h.packets.count == 2 }
            h.callbacks?.receive(CustomEQFixture.firmware()); h.callbacks?.written(2)
            await h.until { !model.busy }
            XCTAssertEqual(model.snapshot["custom_eq_bands"] as? [Int], CustomEQFixture.bands)
            XCTAssertEqual(model.snapshot["firmware_version"] as? String, CustomEQFixture.version)
            switch change {
            case "address": h.select(model, address: "11:22:33:44:55:66", epoch: epoch)
            case "epoch": h.select(model, epoch: UUID())
            case "model": h.select(model, modelName: "Buds4Pro", epoch: epoch)
            default: model.invalidateConnection()
            }
            for key in ["custom_eq_bands", "custom_eq_observed_at", "firmware_version", "firmware_observed_at"] {
                XCTAssertTrue(model.snapshot[key] is NSNull, key)
            }
            model.cancel()
        }
    }

    @MainActor func testPermissionsExpireAndSnapshotNeverQueriesOrMakesUpAReading() async {
        let h = CustomEQHarness(); let model = Model(environment: h.environment()); h.select(model)
        defer { model.cancel() }
        model.perform(.refresh); await h.until { !model.busy }
        for key in ["can_custom_eq_read", "can_custom_eq_write", "can_info"] { XCTAssertEqual(model.snapshot[key] as? Bool, true) }
        h.pendingOperations = 1
        XCTAssertEqual(model.snapshot["can_custom_eq_write"] as? Bool, false)
        h.pendingOperations = 0; h.advance(16)
        for key in ["can_custom_eq_read", "can_custom_eq_write", "can_info"] { XCTAssertEqual(model.snapshot[key] as? Bool, false) }
        for _ in 0..<100 { _ = model.snapshot }
        XCTAssertTrue(h.packets.isEmpty); XCTAssertEqual(h.opens, 1)
        XCTAssertTrue(model.snapshot["custom_eq_bands"] is NSNull); XCTAssertTrue(model.snapshot["firmware_version"] is NSNull)
    }
}
