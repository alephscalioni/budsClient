import XCTest
@testable import BudsAutoSwitch

/// Complete settings transactions through injected effects. No radio or audio.
final class NativeBudsModelCompatibilityTests: XCTestCase {
    typealias P = SamsungBudsSettingsPacket
    typealias Profile = SamsungBudsModelProfile

    private func fixture(_ profile: Profile) -> P.Frame {
        var p = [UInt8](repeating: 0, count: 60)
        p[0] = profile == .budsPlus ? 13 : profile == .budsLive || profile == .budsPro ? 10 : profile == .buds2 ? 9 : 1
        p[2] = 81; p[3] = 72; p[6] = profile == .buds ? 17 : 0x22; p[7] = profile == .buds ? 0 : 64
        p[9] = 1; p[10] = 0xED; p[11] = 1; p[12] = 0
        if profile == .buds { p[10] = 1; p[11] = 2; p[12] = 0 }
        if profile != .buds {
            let offset = profile == .budsPlus ? 15 : 14
            let id = profile.colorIDs.min()!
            for start in [offset, offset + 2] { p[start] = UInt8(truncatingIfNeeded: id); p[start + 1] = UInt8(id >> 8) }
        }
        return .init(command: 0x61, payload: Data(p), isFragment: false, legacyFraming: profile.legacyFraming)
    }

    @MainActor func testEveryModelReadsAndConfirmsItsOwnNoiseAndEqualizerContract() async throws {
        for profile in Profile.allCases {
            let frame = fixture(profile)
            let mode = profile.noiseModes.last!
            for action: NativeBudsSettingsModel.Action in [.noise(mode), .equalizer(2)] {
                let h = CompatibilityHarness(frame: frame)
                let model = NativeBudsSettingsModel(environment: h.environment())
                model.select(address: "AABBCCDDEEFF", name: "Fones", model: profile.rawValue, blocked: false)
                model.perform(action); await h.until { !model.busy }
                XCTAssertNil(model.error, profile.rawValue)
                let packet = try XCTUnwrap(h.packets.first, profile.rawValue)
                let decoded = try XCTUnwrap(P.decodeCompleteFrame(packet))
                if case .noise = action {
                    XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.checks, 1, "One fresh physical session and one OS check per noise change")
                    XCTAssertEqual(decoded.command, profile == .buds || profile == .budsPlus ? 0x80 : profile == .budsLive ? 0x98 : 0x78)
                    XCTAssertEqual(decoded.payload, Data([mode == .ambient && [.buds, .budsPlus].contains(profile) ? 1 : profile == .budsLive ? 1 : mode.rawValue]))
                } else {
                    XCTAssertEqual(decoded.command, 0x86)
                    XCTAssertEqual(decoded.payload, profile == .buds ? Data([1, 6]) : Data([3]))
                }
                XCTAssertEqual(model.batterySnapshot?.model, profile.rawValue)
                XCTAssertEqual(model.batterySnapshot?.left, 81)
                model.cancel()
            }
        }
    }

    @MainActor func testBuds4GesturesPreserveCallAndHoldFieldsWithoutImportingBuds3ProTail() async throws {
        for profile: Profile in [.buds4, .buds4Pro] {
            let h = CompatibilityHarness(frame: fixture(profile))
            let model = NativeBudsSettingsModel(environment: h.environment())
            model.select(address: "AABBCCDDEEFF", name: "Fones", model: profile.rawValue, blocked: false)
            model.perform(.mediaControls(false)); await h.until { !model.busy }
            XCTAssertNil(model.error)
            let frame = try XCTUnwrap(h.packets.first.flatMap { P.decodeCompleteFrame($0) })
            XCTAssertEqual(frame.command, 0x90)
            XCTAssertEqual(frame.payload, Data([1, 0, 0, 0, 1, 0, 1, 0, 1, 1]))
            model.cancel()
        }
    }

    func testFindPlacementUpdatesUseTheSessionModelInsteadOfBuds3RevisionLimits() throws {
        let oldModern = fixture(.buds2)
        let placement = try XCTUnwrap(NativeBudsToolsPacket.placements(oldModern, profile: .buds2))
        XCTAssertEqual(placement.0, .idle); XCTAssertEqual(placement.1, .idle)
        let legacy = P.Frame(command: 0x60, payload: Data([1, 80, 80, 1, 0, 0]), isFragment: false, legacyFraming: true)
        let outside = try XCTUnwrap(NativeBudsToolsPacket.placements(legacy, profile: .buds))
        XCTAssertEqual(outside.0, .idle); XCTAssertEqual(outside.1, .idle)
        let charging = P.Frame(command: 0x60, payload: Data([1, 80, 80, 1, 0, 0x22, 80, 0x14]), isFragment: false)
        let inCase = try XCTUnwrap(NativeBudsToolsPacket.placements(charging, profile: .buds4))
        XCTAssertEqual(inCase.0, .inCase); XCTAssertEqual(inCase.1, .inCase)
        XCTAssertNil(NativeBudsToolsPacket.placements(legacy, profile: .buds4))
    }

    @MainActor func testAmbientLevelUsesExactOneByteCommandAndDoesNotInventFreshBattery() async throws {
        var bytes = fixture(.buds3Pro).payload
        bytes[12] = 2; bytes[23] = 4; bytes[29] = 0
        let frame = P.Frame(command: 0x61, payload: bytes, isFragment: false)
        let status = try XCTUnwrap(P.status(frame, model: "Buds3Pro"))
        XCTAssertEqual(status.levels[.ambient], 4)
        XCTAssertTrue(Profile.buds3Pro.allows(command: 0x84, payload: [3], status: status))
        XCTAssertFalse(Profile.buds3Pro.allows(command: 0x84, payload: [5], status: status))
        XCTAssertFalse(P.acknowledges(.init(command: 0x42, payload: Data([0x84, 1]), isFragment: false), command: 0x84, payload: [3]))
        let h = CompatibilityHarness(frame: frame)
        let model = NativeBudsSettingsModel(environment: h.environment())
        model.select(address: "AABBCCDDEEFF", name: "Fones", model: "Buds3Pro", blocked: false)
        model.perform(.level(.ambient, 3)); await h.until { !model.busy }
        XCTAssertNil(model.error); XCTAssertEqual(h.opens, 1); XCTAssertEqual(h.checks, 1)
        let packet = try XCTUnwrap(h.packets.first.flatMap { P.decodeCompleteFrame($0) })
        XCTAssertEqual(packet.command, 0x84); XCTAssertEqual(packet.payload, Data([3]))
        XCTAssertEqual(model.snapshot["ambient_level"] as? Int, 3)
        XCTAssertEqual(model.batterySnapshot?.observedAt, 1010)
        model.cancel()
    }

    @MainActor func testBuds3ProANCUsesRawFiveLevelContractWithoutBooleanConversion() async throws {
        var bytes = fixture(.buds3Pro).payload; bytes[12] = 1; bytes[24] = 4
        let h = CompatibilityHarness(frame: .init(command: 0x61, payload: bytes, isFragment: false))
        let model = NativeBudsSettingsModel(environment: h.environment())
        model.select(address: "AABBCCDDEEFF", name: "Fones", model: "Buds3Pro", blocked: false)
        model.perform(.level(.anc, 3)); await h.until { !model.busy }
        XCTAssertNil(model.error)
        let packet = try XCTUnwrap(h.packets.first.flatMap { P.decodeCompleteFrame($0) })
        XCTAssertEqual(packet.command, 0x83); XCTAssertEqual(packet.payload, Data([3]))
        let levels = try XCTUnwrap(model.snapshot["levels"] as? [String: Any])
        XCTAssertEqual((levels["anc"] as? [String: Int])?["value"], 3)
        model.cancel()
    }

    func testLevelsRespectCustomizationAndModelSpecificRanges() throws {
        var bytes = fixture(.buds3Pro).payload
        bytes[23] = 4; bytes[29] = 1
        XCTAssertNil(P.Level.observed(Array(bytes), model: "Buds3Pro")[.ambient])
        bytes[29] = 0
        XCTAssertEqual(P.Level.observed(Array(bytes), model: "Buds3Pro")[.ambient], 4)
        XCTAssertEqual(P.Level.observed(Array(bytes), model: "Buds4")[.ambient], 4)
        XCTAssertEqual(P.Level.anc.range(model: "BudsPro"), 0...1)
        XCTAssertEqual(P.Level.anc.range(model: "Buds3Pro"), 0...4)
        XCTAssertEqual(P.Level.anc.range(model: "Buds4"), 0...4)
        XCTAssertEqual(P.Level.anc.range(model: "Buds4Pro"), 0...4)
        XCTAssertNil(P.Level.anc.range(model: "BudsLive"))
        XCTAssertNil(P.Level.ambient.range(model: "BudsLive"))
        XCTAssertEqual(NativeBudsSettingsModel.Action.parse(["action": "device.level", "kind": "ambient", "value": 4]), .level(.ambient, 4))
        for value: Any in [true, -1, 5, 1.5, "2"] {
            XCTAssertNil(NativeBudsSettingsModel.Action.parse(["action": "device.level", "kind": "ambient", "value": value]))
        }
    }

    func testFirmwareReadRejectsAnotherSKUAndLegacyFindHasOwnedStop() {
        for pair in [("Buds4", "R540XXU0AZG2"), ("Buds4Pro", "R640XXU0AZG2")] {
            let frame = P.Frame(command: 0xB4, payload: Data(pair.1.utf8), isFragment: false)
            XCTAssertEqual(SamsungBudsFirmwareVersion.version(frame, model: pair.0), pair.1)
            XCTAssertNil(SamsungBudsFirmwareVersion.version(frame, model: "Buds3Pro"))
        }
        var watchdog = NativeBudsToolsWatchdog()
        watchdog.submitted(.init(command: 0xA0, payload: Data(), isFragment: false), at: 0)
        XCTAssertEqual(watchdog.kind, .find)
        XCTAssertEqual(watchdog.due(at: 180).flatMap { P.decodeCompleteFrame($0) }?.command, 0xA1)
    }
}

@MainActor private final class CompatibilityHarness {
    typealias P = SamsungBudsSettingsPacket
    let frame: P.Frame
    var packets: [Data] = []
    var opens = 0, checks = 0
    var receive: ((P.Frame) -> Void)?
    var written: ((UInt) -> Void)?
    init(frame: P.Frame) { self.frame = frame }
    func environment() -> NativeBudsSettingsEnvironment {
        .init(now: { 10 }, date: { Date(timeIntervalSince1970: 1010) },
            sleep: { try await Task.sleep(for: .seconds($0)) }, connected: { _ in self.checks += 1; return true },
            handlers: { self.receive = $0; self.written = $1; _ = $2 },
            open: { _ in self.opens += 1; self.receive?(self.frame) }, send: { bytes in
                self.packets.append(bytes)
                let packet = P.decodeCompleteFrame(bytes)!
                let receive = self.receive, written = self.written
                Task { @MainActor in
                    await Task.yield()
                    receive?(.init(command: 0x42, payload: Data([packet.command]) + packet.payload, isFragment: false))
                    written?(1)
                }
                return 1
            }, close: {})
    }
    func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 { if predicate() { return }; await Task.yield() }
        XCTFail("Settings transaction did not finish", file: file, line: line)
    }
}
