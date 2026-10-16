import XCTest
@testable import BudsAutoSwitch

final class SamsungMdePacketTests: XCTestCase {
    func testForegroundClassDiagnosticsExcludeAdjacentAccountHash() throws {
        var value = [UInt8](repeating: 0, count: 18)
        value[0] = 0x0B; value[1] = 1; value[2] = 129
        value[3] = 3; value[4] = 2
        value[5] = 185; value[6] = 246 // Deliberately private account-hash bytes.
        value[7] = 1
        let frame = propertyFrame([2, 5, 18] + value)
        let summary = SamsungMdePacket.diagnosticSummary(frame)
        XCTAssertEqual(summary["mde_foreground_version"] as? Int, 3)
        XCTAssertEqual(summary["mde_foreground_major_class"] as? Int, 2)
        XCTAssertNil(summary["account_hash"])
        XCTAssertFalse(summary.values.compactMap { $0 as? Int }.contains(185))
        XCTAssertFalse(summary.values.compactMap { $0 as? Int }.contains(246))
        let malformed = propertyFrame([2, 5, 18] + value + [1, 2, 8])
        let rejected = SamsungMdePacket.diagnosticSummary(malformed)
        XCTAssertEqual(rejected["properties_valid"] as? Bool, false)
        XCTAssertNil(rejected["mde_foreground_major_class"])
    }
    // Incoming notification captured from this user's Buds3 Pro using only the
    // native RFCOMM listener, with zero application commands sent (2026-10-14).
    private let liveNotification: [UInt8] = [0xFC, 0x08, 0x50, 0x01, 0x45, 0x1F,
                                             0x02, 0x01, 0x01, 0xA6, 0xF5, 0xCC]

    func testDecodesHardwareNotificationWithSequenceAndChecksum() throws {
        let decoded = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(Data(liveNotification)))
        XCTAssertEqual(decoded.command, 0x45)
        XCTAssertEqual(decoded.payload, Data([0x1F, 0x02, 0x01, 0x01]))
        XCTAssertEqual(decoded.sequence, 1)
        XCTAssertTrue(decoded.isResponse)
        XCTAssertFalse(decoded.isFragment)
    }

    func testRejectsCorruptionAndIncompleteOrOversizedFrames() {
        var corrupt = liveNotification; corrupt[8] ^= 1
        XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(Data(corrupt)))
        XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(Data(liveNotification.dropLast())))
        XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(Data(liveNotification + [0])))
        XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(Data(repeating: 0, count: 4096)))
    }

    // Fixed vectors reconstructed from the Settings 8.0.8.0 native builder's
    // legacy branch. CRCs were independently calculated with Python crc_hqx.
    // These check byte compatibility, not acceptance by physical earbuds.
    func testComputerSwitchRequestVector() {
        XCTAssertEqual(Array(SamsungMdePacket.requestComputerSwitch()),
                       [0xFC, 0x05, 0x00, 0x01, 0x71, 0x01, 0x79, 0x1C, 0xCC])
    }

    func testVersion3VectorWithUnsetOptionalAccountFields() {
        XCTAssertEqual(Array(SamsungMdePacket.configureVersion3()),
                       [0xFC, 0x0E, 0x00, 0x01, 0x43, 0x04, 0x03, 0x07, 0x00,
                        0x00, 0x0B, 0x03, 0x00, 0x00, 0x00, 0x10, 0x0F, 0xCC])
    }

    func testCRCCheckVector() {
        XCTAssertEqual(SamsungMdePacket.crc16(Array("123456789".utf8)), 0x31C3)
    }

    func testCRCMatchesExistingMultipointPatcherReferenceFrame() {
        // Independent reference already present in MultipointPatcher.cs:
        // FC 0B 00 01 43 04 03 04 00 00 0B 02 1E AF CC.
        XCTAssertEqual(SamsungMdePacket.crc16([0x01, 0x43, 0x04, 0x03, 0x04,
                                              0x00, 0x00, 0x0B, 0x02]), 0xAF1E)
    }
    func testBatteryPropertiesUseExistingAlternativeDecoderIdsAndRejectBrokenTlv() {
        let frame = SamsungMdePacket.Frame(command: 0x44, payload: Data([0, 2, 8, 2, 1, 87, 9, 2, 1, 83, 10, 2, 1, 55]), sequence: 0, isResponse: true, isFragment: false)
        XCTAssertEqual(SamsungMdePacket.batteryProperties(frame), [0x0208: 87, 0x0209: 83, 0x020A: 55])
        let unknown = SamsungMdePacket.Frame(command: 0x45, payload: Data([8, 2, 1, 255, 9, 2, 1, 0]), sequence: 0, isResponse: false, isFragment: false)
        XCTAssertTrue(SamsungMdePacket.batteryProperties(unknown).isEmpty)
        let broken = SamsungMdePacket.Frame(command: 0x45, payload: Data([8, 2, 1, 87, 9, 2, 3, 20]), sequence: 0, isResponse: false, isFragment: false)
        XCTAssertTrue(SamsungMdePacket.batteryProperties(broken).isEmpty)
    }

    func testPlaybackVectorsAndCRC() throws {
        let vectors: [(SamsungMdePacket.PlaybackStatus, [UInt8])] = [
            (.playing, [0xFC, 0x0B, 0, 1, 0x43, 4, 3, 4, 0, 0, 0x0C, 1, 0xEA, 0x06, 0xCC]),
            (.paused, [0xFC, 0x0B, 0, 1, 0x43, 4, 3, 4, 0, 0, 0x0C, 2, 0x89, 0x36, 0xCC])
        ]
        for (status, expected) in vectors {
            let data = SamsungMdePacket.playbackStatus(status)
            XCTAssertEqual(Array(data), expected) // Independent Python binascii.crc_hqx CRCs.
            let decoded = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(data))
            XCTAssertEqual(decoded.command, 0x43)
            XCTAssertEqual(decoded.payload, Data([4, 3, 4, 0, 0, 0x0C, status.rawValue]))
            XCTAssertEqual(decoded.sequence, 0)
            XCTAssertFalse(decoded.isResponse)
            XCTAssertFalse(decoded.isFragment)
            var corrupt = data
            corrupt[11] ^= 1
            XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(corrupt))
        }
    }

    func testOutputDeviceVectorsAndCRC() throws {
        let vectors: [(SamsungMdePacket.OutputDeviceState, [UInt8])] = [
            (.none, [0xFC, 0x0B, 0, 1, 0x43, 4, 3, 4, 0, 0, 0x0E, 0, 0xA9, 0x70, 0xCC]),
            (.single, [0xFC, 0x0B, 0, 1, 0x43, 4, 3, 4, 0, 0, 0x0E, 1, 0x88, 0x60, 0xCC]),
            (.multiple, [0xFC, 0x0B, 0, 1, 0x43, 4, 3, 4, 0, 0, 0x0E, 2, 0xEB, 0x50, 0xCC])
        ]
        for (state, expected) in vectors {
            let data = SamsungMdePacket.outputDeviceState(state)
            XCTAssertEqual(Array(data), expected)
            let decoded = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(data))
            XCTAssertEqual(decoded.command, 0x43)
            XCTAssertEqual(decoded.payload, Data([4, 3, 4, 0, 0, 0x0E, state.rawValue]))
            for end in 0..<data.count {
                XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(Data(data.prefix(end))))
            }
            var corrupt = data
            corrupt[12] ^= 1
            XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(corrupt))
        }
    }

    func testEnumBoundsAndManagedFlagValues() {
        for raw in UInt8.min...UInt8.max {
            XCTAssertEqual(SamsungMdePacket.PlaybackStatus(rawValue: raw) != nil, raw == 1 || raw == 2)
            XCTAssertEqual(SamsungMdePacket.OutputDeviceState(rawValue: raw) != nil, raw <= 2)
            XCTAssertEqual(SamsungMdePacket.MultipointStatus.State(rawValue: raw) != nil, raw <= 1)
        }
        XCTAssertEqual(SamsungMdePacket.PlaybackStatus.playing.rawValue, 1)
        XCTAssertEqual(SamsungMdePacket.PlaybackStatus.paused.rawValue, 2)
        XCTAssertEqual(SamsungMdePacket.OutputDeviceState.none.rawValue, 0)
        XCTAssertEqual(SamsungMdePacket.OutputDeviceState.single.rawValue, 1)
        XCTAssertEqual(SamsungMdePacket.OutputDeviceState.multiple.rawValue, 2)
        XCTAssertEqual(SamsungMdePacket.StreamType.a2dp.rawValue, 1)
        XCTAssertEqual(SamsungMdePacket.StreamType.hfp.rawValue, 2)
        XCTAssertEqual(SamsungMdePacket.StreamType.cisMedia.rawValue, 4)
        XCTAssertEqual(SamsungMdePacket.StreamType.bis.rawValue, 8)
        XCTAssertEqual(SamsungMdePacket.StreamType.cisCall.rawValue, 16)
        XCTAssertEqual(SamsungMdePacket.StreamType.autoSwitchRequest.rawValue, 128)
    }

    // Synthetic TLVs, not device captures. Offsets refer to the TLV value.
    private func multipointTLV(state: UInt8 = 0, stream: UInt8 = 1, reason: UInt8 = 0,
                               length: Int = 18, marker: UInt8 = 0x0B,
                               key: UInt16 = 0x0502) -> [UInt8] {
        var value = [UInt8](repeating: 0, count: length)
        if length > 0 { value[0] = marker }
        if length > 1 { value[1] = state }
        if length > 2 { value[2] = reason }
        if length > 7 { value[7] = stream }
        return [UInt8(truncatingIfNeeded: key), UInt8(key >> 8), UInt8(length)] + value
    }

    private func propertyFrame(_ payload: [UInt8], command: UInt8 = 0x45,
                               fragment: Bool = false, response: Bool = false) -> SamsungMdePacket.Frame {
        SamsungMdePacket.Frame(command: command, payload: Data(payload), sequence: 3,
                               isResponse: response, isFragment: fragment)
    }

    func testMultipointNotificationAndReadResponseUseSameValueOffsets() throws {
        let tlv = multipointTLV(state: 1, stream: 0x12, reason: 132)
        for frame in [propertyFrame(tlv), propertyFrame([0, 2] + tlv, command: 0x44, response: true)] {
            let status = try XCTUnwrap(SamsungMdePacket.multipointStatus(frame))
            XCTAssertEqual(status.state, .background)
            XCTAssertEqual(status.streamType, [.hfp, .cisCall])
            XCTAssertEqual(status.reason, 132)
            XCTAssertTrue(status.isCall)
        }
        let foreground = try XCTUnwrap(SamsungMdePacket.multipointStatus(propertyFrame(multipointTLV())))
        XCTAssertEqual(foreground.state, .foreground)
        XCTAssertEqual(foreground.streamType, .a2dp)
        XCTAssertEqual(foreground.reason, 0)
        XCTAssertFalse(foreground.isCall)
    }

    func testCallClassificationCombinationsAndUnknownValuesArePreserved() throws {
        for raw: UInt8 in [0, 1, 4, 8, 0x80, 0x20, 0x40, 0x8D] {
            let status = try XCTUnwrap(SamsungMdePacket.multipointStatus(
                propertyFrame(multipointTLV(stream: raw, reason: 255))))
            XCTAssertEqual(status.streamType.rawValue, raw)
            XCTAssertEqual(status.reason, 255)
            XCTAssertFalse(status.isCall)
        }
        for raw: UInt8 in [2, 16, 3, 0x14, 0x82, 0x92, 255] {
            let status = try XCTUnwrap(SamsungMdePacket.multipointStatus(
                propertyFrame(multipointTLV(stream: raw))))
            XCTAssertEqual(status.streamType.rawValue, raw)
            XCTAssertTrue(status.isCall)
        }
    }

    func testMultipointRejectsUnsupportedCommandsFragmentsAndMissingData() {
        let tlv = multipointTLV()
        for command: UInt8 in [0, 0x43, 0x71, 255] {
            XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame(tlv, command: command)))
        }
        XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame(tlv, fragment: true)))
        for payload: [UInt8] in [[], [0], [0, 2]] {
            XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame(payload, command: 0x44)))
        }
        XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame([])))
        XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame(multipointTLV(key: 0x0205))))
        XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame(multipointTLV(marker: 0x0C))))
        for raw in UInt8(2)...UInt8.max {
            XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame(multipointTLV(state: raw))))
        }
    }

    func testMultipointLengthBoundsTruncationAndMalformedTrailingTlv() throws {
        for length in 0..<18 {
            XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame(multipointTLV(length: length))))
        }
        for length in [18, 19, 255] {
            let tlv = multipointTLV(length: length)
            XCTAssertNotNil(SamsungMdePacket.multipointStatus(propertyFrame(tlv)))
            for end in 0..<tlv.count {
                XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame(Array(tlv.prefix(end)))))
            }
        }
        let tlv = multipointTLV()
        for suffix: [UInt8] in [[1], [1, 2], [1, 2, 1], [1, 2, 255, 0]] {
            XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame(tlv + suffix)))
        }
        let unrelated: [UInt8] = [8, 2, 1, 87, 0xFF, 0xFF, 0]
        XCTAssertNotNil(SamsungMdePacket.multipointStatus(propertyFrame(unrelated + tlv + unrelated)))
    }

    func testMultipointLastQualifyingTlvWinsWithoutStateAcrossFrames() throws {
        let first = multipointTLV(state: 0, stream: 1)
        let last = multipointTLV(state: 1, stream: 2, reason: 132)
        let status = try XCTUnwrap(SamsungMdePacket.multipointStatus(propertyFrame(first + last)))
        XCTAssertEqual(status.state, .background)
        XCTAssertTrue(status.isCall)
        XCTAssertEqual(status.reason, 132)
        XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame(last + multipointTLV(state: 255))))
        XCTAssertNotNil(SamsungMdePacket.multipointStatus(propertyFrame(last + multipointTLV(marker: 0))))
        XCTAssertNil(SamsungMdePacket.multipointStatus(propertyFrame([8, 2, 1, 87])))
    }

    func testSyntheticMultipointFrameMustPassCRCBeforeInterpretation() throws {
        // Synthetic notification; CRC independently computed with binascii.crc_hqx.
        let data = Data([0xFC, 0x19, 0, 1, 0x45, 2, 5, 0x12, 0x0B, 1, 0x84,
                         0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xD7, 0x77, 0xCC])
        let decoded = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(data))
        XCTAssertEqual(decoded.payload, Data(multipointTLV(state: 1, stream: 2, reason: 132)))
        XCTAssertTrue(try XCTUnwrap(SamsungMdePacket.multipointStatus(decoded)).isCall)
        var corrupt = data
        corrupt[15] ^= 1
        XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(corrupt))
    }
}

extension SamsungMdePacketTests {
    func testOwnedAccountVersion3IndependentPythonGoldenVectorsAndParser() throws {
        // Synthetic fixtures only. Independently generated with hashlib.sha256,
        // binascii.crc_hqx(content, 0), struct.pack('<H', crc) in Python.
        let vectors: [(Data, [UInt8])] = [
            (Data([0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]),
             [0xFC, 0x0E, 0, 1, 0x43, 4, 3, 7, 0, 0, 0x0B, 3, 1, 0x55, 0xC5, 0x83, 0x40, 0xCC]),
            (Data([0, 255]),
             [0xFC, 0x0E, 0, 1, 0x43, 4, 3, 7, 0, 0, 0x0B, 3, 1, 0x06, 0xEB, 0xC3, 0xDE, 0xCC]),
            (Data(repeating: 0xA5, count: 4096),
             [0xFC, 0x0E, 0, 1, 0x43, 4, 3, 7, 0, 0, 0x0B, 3, 1, 0xF6, 0, 0x47, 0x81, 0xCC])
        ]
        for (fingerprint, expected) in vectors {
            let packet = try SamsungMdePacket.configureOwnedAccountVersion3(accountFingerprint: fingerprint)
            XCTAssertEqual(packet, Data(expected))
            XCTAssertNotEqual(packet, SamsungMdePacket.configureVersion3())
            let frame = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(packet))
            XCTAssertEqual(frame.command, 0x43)
            XCTAssertEqual(frame.payload, Data(expected[5..<15]))
            XCTAssertEqual(frame.sequence, 0)
            XCTAssertFalse(frame.isResponse); XCTAssertFalse(frame.isFragment)
            // The seven-byte TLV value is [0, 0, opcode, version, present, h0, h1].
            XCTAssertEqual(frame.payload.prefix(8), Data([4, 3, 7, 0, 0, 0x0B, 3, 1]))
            for end in 0..<packet.count {
                XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(Data(packet.prefix(end))))
            }
            var corrupt = packet; corrupt[13] ^= 1
            XCTAssertNil(SamsungMdePacket.decodeCompleteFrame(corrupt))
            let summary = SamsungMdePacket.diagnosticSummary(frame)
            XCTAssertEqual(Set(summary.keys), ["command", "response", "payload_length"])
        }
    }

    func testOwnedAccountVersion3RejectsUnprovisionedFingerprintLengths() {
        for length in [0, 1, 4097] {
            XCTAssertThrowsError(try SamsungMdePacket.configureOwnedAccountVersion3(
                accountFingerprint: Data(repeating: 0x41, count: length))) {
                XCTAssertEqual($0 as? SamsungMdePacket.Failure, .invalidFingerprint)
            }
        }
    }
}
