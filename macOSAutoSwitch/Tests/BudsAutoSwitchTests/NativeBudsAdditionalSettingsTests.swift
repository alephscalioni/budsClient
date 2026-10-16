import XCTest
@testable import BudsAutoSwitch

private func additionalSettingsStatus(revision: UInt8 = 1, balance: UInt8 = 16) -> SamsungBudsSettingsPacket.Frame {
    var bytes = SettingsWireFixture.status().payload
    bytes[0] = revision
    bytes[25] = balance; bytes[26] = 1; bytes[27] = 2; bytes[28] = 1
    bytes[33] = 1; bytes[34] = 0
    return .init(command: 0x61, payload: bytes, isFragment: false)
}

/// Only injected callbacks and manual time; never constructs a native transport.
@MainActor private final class AdditionalSettingsHarness {
    typealias Packet = SamsungBudsSettingsPacket
    var time: TimeInterval = 0
    var checks = 0
    var opens = 0
    var packets: [Data] = []
    var status = additionalSettingsStatus()
    var receive: ((Packet.Frame) -> Void)?
    var written: ((UInt) -> Void)?
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]

    func environment() -> NativeBudsSettingsEnvironment {
        .init(now: { self.time }, date: { Date(timeIntervalSince1970: 1_000 + self.time) },
            sleep: { try await self.sleep($0) }, connected: { _ in self.checks += 1; return true },
            handlers: { frame, written, _ in self.receive = frame; self.written = written },
            open: { _ in
                self.opens += 1
                if self.opens % 2 == 1 { self.receive?(self.status) }
            }, send: {
                self.packets.append($0)
                return UInt(self.packets.count)
            }, close: {})
    }

    private func sleep(_ seconds: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { sleepers[id] = (time + seconds, $0) }
        } onCancel: {
            Task { @MainActor in self.sleepers.removeValue(forKey: id)?.1.resume(throwing: CancellationError()) }
        }
    }
    var responseWaiting: Bool { sleepers.values.contains { $0.0 == time + 5 } }
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
        XCTFail("Fake settings operation did not reach the expected state", file: file, line: line)
    }
    func select(_ model: NativeBudsSettingsModel, modelName: String = "Buds3Pro") {
        model.select(address: "AA:BB:CC:DD:EE:FF", name: "Galaxy Buds3 Pro", model: modelName, blocked: false)
    }
}

final class NativeBudsAdditionalSettingsTests: XCTestCase {
    typealias Packet = SamsungBudsSettingsPacket
    typealias Model = NativeBudsSettingsModel

    @MainActor private func jsonAction(_ key: String, _ value: String) throws -> Model.Action? {
        let json = "{\"action\":\"device.setting\",\"key\":\"\(key)\",\"value\":\(value)}"
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return Model.Action.parse(request)
    }

    func testStereoBalanceMappingAndStrictUnclampedRange() {
        let setting = Packet.Setting.stereoBalance
        XCTAssertEqual(setting.rawValue, "stereo_balance")
        XCTAssertEqual(setting.command, 143)
        XCTAssertEqual(setting.statusOffset, 25)
        XCTAssertEqual(setting.values, 0...32)
        XCTAssertFalse(setting.isBoolean)
        XCTAssertEqual(Packet.Setting.forCommand(143), setting)
        for value in 0...32 { XCTAssertEqual(setting.wireValue(value), UInt8(value)) }
        for value in [Int.min, -256, -1, 33, 255, 256, Int.max] {
            XCTAssertNil(setting.wireValue(value), "Must reject rather than clamp or truncate \(value)")
        }
    }

    @MainActor func testNumericParserUsesEachSettingsRangeAndRejectsBooleanConfusion() throws {
        let cases: [(Packet.Setting, ClosedRange<Int>)] = [(.stereoBalance, 0...32), (.conversationTimeout, 0...2)]
        for (setting, values) in cases {
            for value in values {
                XCTAssertEqual(try jsonAction(setting.rawValue, "\(value)"), .setting(setting, value))
            }
            XCTAssertEqual(try jsonAction(setting.rawValue, "\(values.upperBound).0"), .setting(setting, values.upperBound))
            for value in ["true", "false", "-1", "\(values.upperBound + 1)", "0.5", "1e100", "\"1\"", "null", "[]", "{}"] {
                XCTAssertNil(try jsonAction(setting.rawValue, value), "\(setting.rawValue): \(value)")
            }
            for value: Any in [Double.nan, Double.infinity, -Double.infinity, Int.min, Int.max, UInt64.max] {
                XCTAssertNil(Model.Action.parse(["action": "device.setting", "key": setting.rawValue, "value": value]))
            }
        }
        XCTAssertNil(Model.Action.parse(["action": "device.setting", "key": "stereo_balance"]))
        for key in ["StereoBalance", "seamless_connection", "ambient_volume", "anc_level", "lighting"] {
            XCTAssertNil(try jsonAction(key, "0"))
        }
    }

    @MainActor func testBooleanSettingsStillRequireActualJSONBooleans() throws {
        for setting in Packet.Setting.allCases where setting.isBoolean {
            XCTAssertEqual(setting.values, 0...1)
            XCTAssertEqual(try jsonAction(setting.rawValue, "true"), .setting(setting, 1))
            XCTAssertEqual(try jsonAction(setting.rawValue, "false"), .setting(setting, 0))
            for value in ["0", "1", "2", "1.0", "0.5", "\"true\"", "null"] {
                XCTAssertNil(try jsonAction(setting.rawValue, value), "\(setting.rawValue): \(value)")
            }
        }
    }

    func testObservedStereoBalanceUsesByte25AndPreservesIndependentSettings() throws {
        let expected: [Packet.Setting: Int] = [
            .stereoBalance: 16, .conversationDetection: 1, .conversationTimeout: 2,
            .oneEarbudNoiseControl: 1, .sidetone: 1, .callAudioToBuds: 1
        ]
        for revision: UInt8 in 1...4 {
            for value: UInt8 in 0...32 {
                let frame = additionalSettingsStatus(revision: revision, balance: value)
                var settings = expected; settings[.stereoBalance] = Int(value)
                XCTAssertEqual(try XCTUnwrap(Packet.status(frame, model: "Buds3Pro")).settings, settings)
            }
        }
        for value: UInt8 in [33, 255] {
            let frame = additionalSettingsStatus(balance: value)
            var settings = expected; settings.removeValue(forKey: .stereoBalance)
            XCTAssertEqual(try XCTUnwrap(Packet.status(frame, model: "Buds3Pro")).settings, settings)
        }
        let bytes = additionalSettingsStatus().payload
        XCTAssertNil(Packet.Setting.stereoBalance.observedValue(Array(bytes.prefix(25))))
        XCTAssertEqual(Packet.Setting.observed(Array(bytes.prefix(26))), [.stereoBalance: 16])
        for revision: UInt8 in [0, 5, 255] {
            XCTAssertTrue(try XCTUnwrap(Packet.status(additionalSettingsStatus(revision: revision), model: "Buds3Pro")).settings.isEmpty)
        }
    }

    func testByteExactScalarEncodingKeepsTimeoutAndCallPathInversion() throws {
        // Fixed CCITT-zero vectors, calculated independently of Packet.frame.
        let cases: [(Packet.Setting, Int, [UInt8])] = [
            (.stereoBalance, 0, [0xFD, 4, 0, 0x8F, 0, 0xA6, 0x0B, 0xDD]),
            (.stereoBalance, 16, [0xFD, 4, 0, 0x8F, 16, 0x97, 0x19, 0xDD]),
            (.stereoBalance, 32, [0xFD, 4, 0, 0x8F, 32, 0xC4, 0x2F, 0xDD]),
            (.conversationTimeout, 0, [0xFD, 4, 0, 0x7B, 0, 0xA3, 0xD4, 0xDD]),
            (.conversationTimeout, 1, [0xFD, 4, 0, 0x7B, 1, 0x82, 0xC4, 0xDD]),
            (.conversationTimeout, 2, [0xFD, 4, 0, 0x7B, 2, 0xE1, 0xF4, 0xDD]),
            (.callAudioToBuds, 0, [0xFD, 4, 0, 0x6E, 1, 0x04, 0x38, 0xDD]),
            (.callAudioToBuds, 1, [0xFD, 4, 0, 0x6E, 0, 0x25, 0x28, 0xDD])
        ]
        for (setting, value, expected) in cases {
            let wire = try XCTUnwrap(setting.wireValue(value))
            XCTAssertEqual(Packet.frame(command: setting.command, payload: [wire]), Data(expected))
            XCTAssertTrue(Packet.acknowledges(SettingsWireFixture.ack(setting.command, [wire]), command: setting.command, payload: [wire]))
        }
        for raw: UInt8 in [0, 1] {
            var bytes = additionalSettingsStatus().payload; bytes[34] = raw
            XCTAssertEqual(Packet.Setting.callAudioToBuds.observedValue(Array(bytes)), 1 - Int(raw))
        }
        XCTAssertNil(Packet.Setting.conversationTimeout.wireValue(3))
        XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(123, [3]), command: 123, payload: [3]))
    }

    func testStereoBalanceRequiresExactSingleByteACKWithinRange() {
        for value: UInt8 in 0...32 {
            XCTAssertTrue(Packet.acknowledges(SettingsWireFixture.ack(143, [value]), command: 143, payload: [value]))
        }
        for payload: [UInt8] in [[], [33], [255], [16, 0]] {
            XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(143, payload), command: 143, payload: payload))
        }
        for frame in [SettingsWireFixture.ack(143, [0]), SettingsWireFixture.ack(139, [16]),
                      SettingsWireFixture.ack(143, [16, 0]),
                      Packet.Frame(command: 0x42, payload: Data([143, 16]), isFragment: true),
                      Packet.Frame(command: 143, payload: Data([16]), isFragment: false)] {
            XCTAssertFalse(Packet.acknowledges(frame, command: 143, payload: [16]))
        }
    }

    func testConfirmedStereoBalanceChangesOnlyByte25OfStoredStatus() throws {
        var bytes = additionalSettingsStatus().payload
        for offset in 29...32 { bytes[offset] = UInt8(190 + offset) }
        let original = Packet.Frame(command: 0x61, payload: bytes, isFragment: false)
        var evidence = NativeBudsSettingsEvidence()
        let generation = evidence.generation, owner = UUID(), date = Date(timeIntervalSince1970: 1_000)
        evidence.receive(original, at: 7, date: date, generation: generation, owner: nil)
        XCTAssertTrue(evidence.arm(.init(command: 143, payload: Data([32]), isFragment: false), owner: owner))
        evidence.track(1, owner: owner)
        evidence.written(1, generation: generation, owner: owner)
        evidence.receive(SettingsWireFixture.ack(143, [0]), at: 8, date: date, generation: generation, owner: owner)
        XCTAssertEqual(evidence.observation?.frame, original)
        evidence.receive(SettingsWireFixture.ack(143, [32]), at: 9, date: date, generation: generation, owner: owner)
        var expected = bytes; expected[25] = 32
        let observation = try XCTUnwrap(evidence.observation)
        XCTAssertEqual(observation.frame, .init(command: 0x61, payload: expected, isFragment: false))
        XCTAssertEqual(observation.monotonic, 7)
        XCTAssertEqual(observation.date, date)
    }

    @MainActor func testStereoBalanceWritePreservesOtherFieldsAndWaitsForBothConfirmationSignals() async throws {
        let cases: [(Int, [UInt8])] = [
            (0, [0xFD, 4, 0, 0x8F, 0, 0xA6, 0x0B, 0xDD]),
            (32, [0xFD, 4, 0, 0x8F, 32, 0xC4, 0x2F, 0xDD])
        ]
        for (value, expected) in cases {
            let h = AdditionalSettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
            defer { model.cancel() }
            model.perform(["action": "device.setting", "key": "stereo_balance", "value": value])
            await h.until { h.packets.count == 1 && h.responseWaiting }
            XCTAssertEqual(h.packets, [Data(expected)], "Only the absolute balance byte may be sent")
            let before = model.snapshot
            let settings = try XCTUnwrap(before["settings"] as? [String: Any])
            XCTAssertEqual(settings["stereo_balance"] as? Int, 16)
            h.receive?(SettingsWireFixture.ack(139, [UInt8(value)]))
            h.receive?(SettingsWireFixture.ack(143, [UInt8(value ^ 1)]))
            h.receive?(SettingsWireFixture.ack(143, [UInt8(value), 0]))
            XCTAssertTrue(model.busy)
            if value == 0 { h.receive?(SettingsWireFixture.ack(143, [UInt8(value)])) }
            else { h.written?(1) }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(model.busy, "Neither an exact echo nor a write completion alone confirms the change")
            XCTAssertEqual((model.snapshot["settings"] as? [String: Any])?["stereo_balance"] as? Int, 16)
            if value == 0 { h.written?(1) }
            else { h.receive?(SettingsWireFixture.ack(143, [UInt8(value)])) }
            await h.until { !model.busy }
            XCTAssertNil(model.error)
            let after = model.snapshot
            var expectedSettings = settings; expectedSettings["stereo_balance"] = value
            XCTAssertEqual(try XCTUnwrap(after["settings"] as? NSDictionary), NSDictionary(dictionary: expectedSettings))
            for key in ["noise_mode", "equalizer", "ambient_level", "touch_enabled", "touch_controls",
                        "media_controls_enabled", "media_controls_mixed", "observed_at", "last_observation"] {
                XCTAssertEqual(try XCTUnwrap(after[key] as? NSObject), try XCTUnwrap(before[key] as? NSObject), key)
            }
            XCTAssertEqual(model.batterySnapshot?.observedAt, 1_000)
            XCTAssertEqual(h.packets.count, 1)
        }
    }

    @MainActor func testInvalidDirectValuesAndUnsupportedModelsCannotReachTransport() {
        for value in [Int.min, -1, 33, 256, Int.max] {
            let h = AdditionalSettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
            model.perform(.setting(.stereoBalance, value))
            XCTAssertFalse(model.busy); XCTAssertEqual(h.checks, 0); XCTAssertEqual(h.opens, 0)
            XCTAssertTrue(h.packets.isEmpty); XCTAssertNotNil(model.error)
            model.cancel()
        }
        for name in ["BudsPro", "Buds2Pro", "Buds3", "Buds3Fe", "Buds4", "Buds4Pro"] {
            let h = AdditionalSettingsHarness(); let model = Model(environment: h.environment()); h.select(model, modelName: name)
            model.perform(.setting(.stereoBalance, 16))
            XCTAssertFalse(model.busy); XCTAssertEqual(h.checks, 0); XCTAssertEqual(h.opens, 0)
            XCTAssertTrue(h.packets.isEmpty)
            XCTAssertNil(Packet.status(h.status, model: name))
            model.cancel()
        }
    }

    @MainActor func testUnobservedBalanceAndFutureRevisionsCannotAuthorizeWrites() async {
        var truncated = additionalSettingsStatus()
        truncated = .init(command: truncated.command, payload: Data(truncated.payload.prefix(25)), isFragment: false)
        for frame in [additionalSettingsStatus(balance: 33), additionalSettingsStatus(balance: 255),
                      additionalSettingsStatus(revision: 0), additionalSettingsStatus(revision: 5), truncated] {
            let h = AdditionalSettingsHarness(); h.status = frame
            let model = Model(environment: h.environment()); h.select(model)
            model.perform(.setting(.stereoBalance, 16))
            await h.until { !model.busy }
            XCTAssertEqual(h.opens, 1); XCTAssertTrue(h.packets.isEmpty); XCTAssertNotNil(model.error)
            model.cancel()
        }
    }

    @MainActor func testWrongBalanceEchoTimesOutWithoutPublishingRequestedValue() async throws {
        let h = AdditionalSettingsHarness(); let model = Model(environment: h.environment()); h.select(model)
        defer { model.cancel() }
        model.perform(.setting(.stereoBalance, 32))
        await h.until { h.packets.count == 1 && h.responseWaiting }
        h.written?(1); h.receive?(SettingsWireFixture.ack(143, [0]))
        XCTAssertTrue(model.busy)
        h.advance(5)
        await h.until { !model.busy }
        XCTAssertNotNil(model.error); XCTAssertEqual(h.packets.count, 1); XCTAssertEqual(h.opens, 2)
        XCTAssertTrue((model.snapshot["settings"] as? [String: Any])?.isEmpty == true)
        let history = try XCTUnwrap(model.snapshot["last_observation"] as? [String: Any])
        XCTAssertEqual((history["settings"] as? [String: Any])?["stereo_balance"] as? Int, 16)
        XCTAssertEqual(history["settings_may_have_changed"] as? Bool, true)
    }
}
