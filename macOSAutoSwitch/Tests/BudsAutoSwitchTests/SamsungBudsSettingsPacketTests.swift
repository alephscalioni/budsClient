import XCTest
@testable import BudsAutoSwitch

final class SamsungBudsSettingsPacketTests: XCTestCase {
    typealias Packet = SamsungBudsSettingsPacket

    // Hand-derived CCITT-zero vectors, not device captures or an encoder round trip.
    private let noiseOff = Data([0xFD, 4, 0, 0x78, 0, 0xF0, 0x81, 0xDD])
    private let noiseANC = Data([0xFD, 4, 0, 0x78, 1, 0xD1, 0x91, 0xDD])

    func testOriginalScalarSettingsDecodeIndependentOffsetsAndPreserveCallPathInversion() throws {
        var bytes = SettingsWireFixture.status().payload
        bytes[26] = 1; bytes[27] = 2; bytes[28] = 0; bytes[33] = 1; bytes[34] = 0
        let settings = try XCTUnwrap(Packet.status(.init(command: 0x61, payload: bytes, isFragment: false), model: "Buds3Pro")).settings
        XCTAssertEqual(settings[.conversationDetection], 1)
        XCTAssertEqual(settings[.conversationTimeout], 2)
        XCTAssertEqual(settings[.oneEarbudNoiseControl], 0)
        XCTAssertEqual(settings[.sidetone], 1)
        XCTAssertEqual(settings[.callAudioToBuds], 1)
        XCTAssertEqual(Packet.Setting.callAudioToBuds.wireValue(1), 0)
        XCTAssertEqual(Packet.Setting.callAudioToBuds.wireValue(0), 1)
        bytes[26] = 2; bytes[27] = 3; bytes[34] = 255
        let invalid = try XCTUnwrap(Packet.status(.init(command: 0x61, payload: bytes, isFragment: false), model: "Buds3Pro")).settings
        XCTAssertNil(invalid[.conversationDetection]); XCTAssertNil(invalid[.conversationTimeout]); XCTAssertNil(invalid[.callAudioToBuds])
        XCTAssertEqual(invalid[.sidetone], 1, "An invalid neighbor must not erase a valid reading")
        bytes[0] = 5
        XCTAssertTrue(try XCTUnwrap(Packet.status(.init(command: 0x61, payload: bytes, isFragment: false), model: "Buds3Pro")).settings.isEmpty)
    }

    func testOriginalScalarSettingsRequireExactCommandValueEcho() {
        for command: UInt8 in [110, 111, 122, 139] {
            XCTAssertTrue(Packet.acknowledges(SettingsWireFixture.ack(command, [0]), command: command, payload: [0]))
            XCTAssertTrue(Packet.acknowledges(SettingsWireFixture.ack(command, [1]), command: command, payload: [1]))
            XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(command, [0]), command: command, payload: [1]))
            XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(command, [2]), command: command, payload: [2]))
        }
        XCTAssertTrue(Packet.acknowledges(SettingsWireFixture.ack(123, [2]), command: 123, payload: [2]))
        XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(123, [3]), command: 123, payload: [3]))
        XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(175, [0]), command: 175, payload: [0]), "This extension cannot silently alter seamless connection")
    }

    func testNormalProfileGoldenVectorsAndSevenByteMinimum() throws {
        XCTAssertEqual(Packet.frame(command: 0x78, payload: [0]), noiseOff)
        XCTAssertEqual(Packet.frame(command: 0x78, payload: [1]), noiseANC)
        let decoded = try XCTUnwrap(Packet.decodeCompleteFrame(noiseANC))
        XCTAssertEqual(decoded.command, 0x78)
        XCTAssertEqual(decoded.payload, Data([1]))
        let minimum = Data([0xFD, 3, 0, 0, 0, 0, 0xDD])
        XCTAssertEqual(Packet.decodeCompleteFrame(minimum)?.payload, Data())
        XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(noiseANC))
        XCTAssertNil(Packet.decodeCompleteFrame(SamsungMdePacket.requestComputerSwitch()))
    }

    func testCRCHeaderLengthTrailerAndWrongProfileAreRejected() {
        for offset in [0, 1, 3, 4, 5, 6, 7] {
            var invalid = noiseANC; invalid[offset] ^= 1
            XCTAssertNil(Packet.decodeCompleteFrame(invalid), "Corruption at \(offset)")
        }
        XCTAssertNil(Packet.decodeCompleteFrame(noiseANC + Data([0])))
        for length in 0..<noiseANC.count { XCTAssertNil(Packet.decodeCompleteFrame(Data(noiseANC.prefix(length)))) }
        XCTAssertNil(Packet.decodeCompleteFrame(Data(repeating: 0, count: 1028)))
    }

    func testEverySplitBatchExpiryAndProfileIsolation() throws {
        for split in 1..<noiseANC.count {
            var stream = Packet.Stream()
            XCTAssertTrue(try stream.append(Data(noiseANC.prefix(split)), at: 0).isEmpty)
            let result = try stream.append(Data(noiseANC.dropFirst(split)) + noiseOff, at: 0.1)
            XCTAssertEqual(result.map(\.payload), [Data([1]), Data([0])])
            XCTAssertTrue(stream.buffer.isEmpty)
        }
        var stream = Packet.Stream()
        XCTAssertTrue(try stream.append(Data(noiseANC.prefix(5)), at: 0).isEmpty)
        XCTAssertTrue(try stream.append(Data(noiseANC.dropFirst(5)), at: 2).isEmpty)
        var corrupt = noiseANC; corrupt[4] ^= 1
        let result = try stream.append(SamsungMdePacket.requestComputerSwitch() + corrupt + noiseANC, at: 3)
        XCTAssertEqual(result.map(\.command), [0x78])
        var smep = NativeBudsFrameStream()
        XCTAssertTrue(try smep.append(noiseANC, at: 0).isEmpty)
    }

    func testFragmentIsNeverACompleteStatusOrACKAndGarbageIsBounded() throws {
        var fragment = noiseANC; fragment[2] |= 0x20
        var stream = Packet.Stream()
        XCTAssertTrue(try stream.append(fragment, at: 0).isEmpty)
        XCTAssertEqual(stream.fragmentCount, 1)
        XCTAssertThrowsError(try stream.append(Data(repeating: 0, count: 4097), at: 0))
        for i in 0..<8 { XCTAssertTrue(try stream.append(Data(repeating: 0, count: 4096), at: Double(i)).isEmpty) }
        XCTAssertThrowsError(try stream.append(Data([0]), at: 9))
    }

    func testCommonStatusOffsetsAgainstIndependentPayload() throws {
        let status = try XCTUnwrap(Packet.status(SettingsWireFixture.status(), model: "Buds3Pro"))
        XCTAssertEqual(status.left, 0)
        XCTAssertEqual(status.right, 100)
        XCTAssertEqual(status.casePercent, 53)
        XCTAssertEqual(status.noise, .ambient)
        XCTAssertEqual(status.equalizer, 4) // Wire 5, not UI 5.
        XCTAssertEqual(status.ambientLevel, 2)
        XCTAssertTrue(status.touchEnabled)
        XCTAssertEqual(status.touchControls?.payload(enabled: false), [0, 1, 1, 0, 1, 0, 1, 0, 2, 3])
        XCTAssertNil(Packet.status(SettingsWireFixture.status(), model: "Buds2Pro"))
        let short = Array(SettingsWireFixture.status().payload.prefix(24))
        XCTAssertNil(Packet.status(.init(command: 0x61, payload: Data(short), isFragment: false), model: "Buds3Pro"))
        XCTAssertNil(Packet.status(.init(command: 0x61, payload: SettingsWireFixture.status().payload, isFragment: true), model: "Buds3Pro"))
    }

    func testUnknownReadingsStayUnknownAndEQDisabledIsNotPresetZero() throws {
        var bytes = [UInt8](SettingsWireFixture.status().payload)
        bytes[2] = 101; bytes[3] = 255; bytes[7] = 200
        bytes[9] = 0; bytes[12] = 4
        let frame = Packet.Frame(command: 0x61, payload: Data(bytes), isFragment: false)
        let value = try XCTUnwrap(Packet.status(frame, model: "Buds3Pro"))
        XCTAssertNil(value.left); XCTAssertNil(value.right); XCTAssertNil(value.casePercent)
        XCTAssertNil(value.equalizer); XCTAssertNil(value.noise)
        XCTAssertEqual(value.rawEqualizer, 0)
        bytes[9] = 7
        XCTAssertNil(Packet.status(.init(command: 0x61, payload: Data(bytes), isFragment: false), model: "Buds3Pro")?.equalizer)
        bytes[6] = 0xF1
        XCTAssertNil(Packet.status(.init(command: 0x61, payload: Data(bytes), isFragment: false), model: "Buds3Pro"))
    }

    func testSamsungMediaSwitchPreservesMasterCallsAndTypesAndKeepsHoldOn() throws {
        let disabledMaster = try XCTUnwrap(Packet.TouchControls(bitfield: 0x12, lightingControl: 2, doublePinchAndHold: 3))
        XCTAssertEqual(disabledMaster.mediaPayload(enabled: true), [0, 1, 1, 1, 1, 1, 0, 1, 2, 3])
        let enabled = try XCTUnwrap(Packet.TouchControls(bitfield: 0xFF, lightingControl: 7, doublePinchAndHold: 9))
        XCTAssertEqual(enabled.mediaEnabled, true)
        XCTAssertEqual(enabled.mediaPayload(enabled: false), [1, 0, 0, 0, 1, 1, 1, 0, 7, 9])
        XCTAssertEqual(Packet.TouchControls(bitfield: 0xB1, lightingControl: 0, doublePinchAndHold: 0)?.mediaEnabled, false)
        XCTAssertNil(disabledMaster.mediaEnabled, "Individual media options must remain mixed, not an invented master state")
    }

    func testIndividualGesturesPreserveOtherFieldsAndSamsungHoldRuleAcrossAllBitfields() throws {
        let indices = [1, 2, 3, 7, 5, 6]
        for bits in UInt8.min...UInt8.max {
            let controls = try XCTUnwrap(Packet.TouchControls(bitfield: bits, lightingControl: 7, doublePinchAndHold: 255))
            let original = controls.payload(enabled: controls.enabled)
            for (gesture, index) in zip(Packet.Gesture.allCases, indices) {
                XCTAssertEqual(gesture.parameterIndex, index)
                XCTAssertEqual(controls.fields[gesture.rawValue], original[index] == 1)
                for enabled in [false, true] {
                    var expected = original; expected[index] = enabled ? 1 : 0; expected[4] = 1
                    let payload = controls.payload(changing: gesture, enabled: enabled)
                    XCTAssertEqual(payload, expected)
                    XCTAssertTrue(controls.admitsIndividualUpdate(payload))
                    XCTAssertEqual(controls.replacing(with: payload)?.payload(enabled: controls.enabled), payload)
                    for collateral in [0, 8, 9] {
                        var malformed = payload; malformed[collateral] ^= 1
                        XCTAssertFalse(controls.admitsIndividualUpdate(malformed))
                    }
                }
            }
        }
    }

    func testTouchPreservesSwipeAndTypesAndRefusesIncompleteState() throws {
        let controls = try XCTUnwrap(Packet.TouchControls(bitfield: 0x12, lightingControl: 2, doublePinchAndHold: 3))
        XCTAssertEqual(controls.payload(enabled: true), [1, 0, 0, 1, 0, 1, 0, 0, 2, 3])
        XCTAssertEqual(controls.payload(enabled: false), [0, 0, 0, 1, 0, 1, 0, 0, 2, 3])
        XCTAssertNil(Packet.TouchControls(bitfield: 0xFF))
        XCTAssertEqual(Packet.TouchControls(bitfield: 0xFF, lightingControl: 7, doublePinchAndHold: 255)?.payload(enabled: false), [0, 1, 1, 1, 1, 1, 1, 1, 7, 255])
        let ack = SettingsWireFixture.ack(0x90, [0, 1, 1, 0, 1, 0, 1, 0, 2, 3])
        XCTAssertTrue(Packet.acknowledges(ack, command: 0x90, payload: [0, 1, 1, 0, 1, 0, 1, 0, 2, 3]))
        XCTAssertFalse(Packet.acknowledges(ack, command: 0x90, payload: [0, 1, 1, 0, 1, 1, 1, 0, 2, 3]))
        XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(0x90, [0]), command: 0x90, payload: [0, 1, 1, 0, 1, 0, 1, 0, 2, 3]))
    }

    func testACKEchoValueIsNotSuccessCodeAndNoiseUpdatesAreStrict() {
        XCTAssertTrue(Packet.acknowledges(SettingsWireFixture.ack(0x78, [0]), command: 0x78, payload: [0]))
        XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(0x78, [0]), command: 0x78, payload: [1]))
        XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(0x86, [1]), command: 0x78, payload: [1]))
        XCTAssertTrue(Packet.acknowledges(SettingsWireFixture.ack(0x86, [6]), command: 0x86, payload: [6]))
        XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(0x86, [0]), command: 0x86, payload: [0]))
        XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(0x78, [4]), command: 0x78, payload: [4]))
        for wear in [UInt8(0), 1, 16, 17] {
            XCTAssertEqual(Packet.noiseUpdate(.init(command: 0x77, payload: Data([3, wear]), isFragment: false)), .adaptive)
        }
        let invalidPayloads: [[UInt8]] = [[], [4], [1, 2], [1, 0, 0]]
        for payload in invalidPayloads {
            XCTAssertNil(Packet.noiseUpdate(.init(command: 0x77, payload: Data(payload), isFragment: false)))
        }
        XCTAssertNil(Packet.noiseUpdate(.init(command: 0x77, payload: Data([1]), isFragment: true)))
    }

    func testPhysicalIdentityRequiresBothColorsAndRejectsExplicitOtherModel() {
        let fixture = SettingsWireFixture.status()
        XCTAssertEqual(Packet.physicalBuds3Pro(fixture), true)
        var bytes = fixture.payload
        bytes[14] = 0x55
        XCTAssertEqual(Packet.physicalBuds3Pro(.init(command: 0x61, payload: bytes, isFragment: false)), true)
        bytes[16] = 0; bytes[17] = 0
        XCTAssertNil(Packet.physicalBuds3Pro(.init(command: 0x61, payload: bytes, isFragment: false)))
        bytes[16] = 0x4D; bytes[17] = 1 // 333 = Buds3, not Buds3 Pro
        let different = Packet.Frame(command: 0x61, payload: bytes, isFragment: false)
        XCTAssertEqual(Packet.physicalBuds3Pro(different), false)
        XCTAssertNil(Packet.status(different, model: "Buds3Pro"))
    }

    func testCaseZeroIsActualZeroAndDisconnectedOr255AreUnknown() {
        for (wire, expected) in [(UInt8(0), Optional(0)), (100, Optional(100)), (101, nil), (255, nil)] {
            var bytes = SettingsWireFixture.status().payload; bytes[7] = wire
            XCTAssertEqual(Packet.status(.init(command: 0x61, payload: bytes, isFragment: false), model: "Buds3Pro")?.casePercent, expected)
        }
    }

    func testTouchRequiresObservedTypesKnownRevisionAndExactSwipeAndTypesEcho() throws {
        let fixture = SettingsWireFixture.status(touch: 0xED)
        let value = try XCTUnwrap(Packet.status(fixture, model: "Buds3Pro")?.touchControls)
        let expected: [UInt8] = [0, 1, 1, 0, 1, 0, 1, 1, 2, 3]
        XCTAssertEqual(value.payload(enabled: false), expected)
        for count in [25, 51, 52] {
            XCTAssertNil(Packet.status(.init(command: 0x61, payload: Data(fixture.payload.prefix(count)), isFragment: false), model: "Buds3Pro")?.touchControls)
        }
        var future = fixture.payload; future[0] = 5
        XCTAssertNil(Packet.status(.init(command: 0x61, payload: future, isFragment: false), model: "Buds3Pro")?.touchControls)
        for index in [7, 8, 9] {
            var wrong = expected; wrong[index] ^= 1
            XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(0x90, wrong), command: 0x90, payload: expected))
        }
        XCTAssertFalse(Packet.acknowledges(SettingsWireFixture.ack(0x90, Array(expected.prefix(7))), command: 0x90, payload: expected))
        XCTAssertTrue(Packet.acknowledges(SettingsWireFixture.ack(0x90, expected), command: 0x90, payload: expected))
    }

    @MainActor func testTransportConfigurationsRejectCrossProfilePacketsAndDefaultRemainsSMEP() {
        let transport = NativeBudsTransport() // No open; construction has no radio effects.
        XCTAssertEqual(transport.configuration, .smep)
        XCTAssertEqual(transport.configuration.serviceUUID, "F8620674-A1ED-41AB-A8B9-DE9AD655729D")
        XCTAssertEqual(NativeBudsTransport.Configuration.sppNew.serviceUUID, "2e73a4ad-332d-41fc-90e2-16bef06523f2")
        let smep = SamsungMdePacket.requestComputerSwitch()
        XCTAssertTrue(NativeBudsTransport.Configuration.smep.acceptsPacket(smep))
        XCTAssertFalse(NativeBudsTransport.Configuration.smep.acceptsPacket(noiseANC))
        XCTAssertTrue(NativeBudsTransport.Configuration.sppNew.acceptsPacket(noiseANC))
        XCTAssertFalse(NativeBudsTransport.Configuration.sppNew.acceptsPacket(smep))
        var fragment = noiseANC; fragment[2] |= 0x20
        XCTAssertFalse(NativeBudsTransport.Configuration.sppNew.acceptsPacket(fragment))
    }
}

/// Independent common-prefix bytes with deliberately different values at nearby
/// offsets (not an encoded copy of expected Swift model fields).
enum SettingsWireFixture {
    static func status(touch: UInt8 = 0xAD, equalizer: UInt8 = 5) -> SamsungBudsSettingsPacket.Frame {
        var bytes: [UInt8] = [
            1, 0, 0, 100, 1, 0, 0x12, 53, 1, equalizer, touch, 0x34, 2,
            0, 0x54, 1, 0x54, 1, 0, 0, 0, 0x91, 0, 2, 1
        ]
        bytes += Array(repeating: 0, count: 26)
        bytes += [2, 3] // lighting and advanced-hold types at 51/52
        return .init(command: 0x61, payload: Data(bytes), isFragment: false)
    }
    static func ack(_ command: UInt8, _ values: [UInt8]) -> SamsungBudsSettingsPacket.Frame {
        .init(command: 0x42, payload: Data([command] + values), isFragment: false)
    }
}
