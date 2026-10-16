import Foundation
import CryptoKit

/// Offline reconstruction of the legacy SPP framing used by EasyConnect2.dll.
/// No transport calls or automatic activation: account eligibility and acceptance
/// by the connected Buds firmware still require a separate device experiment.
enum SamsungMdePacket {
    enum Failure: String, Error { case invalidFingerprint, invalidOwnedConfiguration }

    enum PlaybackStatus: UInt8 {
        case playing = 1
        case paused = 2
    }

    enum OutputDeviceState: UInt8 {
        case none = 0
        case single = 1
        case multiple = 2
    }

    /// Flags from DllBudsMsgFmtManager.StreamType; unknown bits are preserved.
    struct StreamType: OptionSet, Equatable {
        let rawValue: UInt8
        static let a2dp = StreamType(rawValue: 0x01)
        static let hfp = StreamType(rawValue: 0x02)
        static let cisMedia = StreamType(rawValue: 0x04)
        static let bis = StreamType(rawValue: 0x08)
        static let cisCall = StreamType(rawValue: 0x10)
        static let autoSwitchRequest = StreamType(rawValue: 0x80)
    }

    struct MultipointStatus: Equatable {
        enum State: UInt8 {
            case foreground = 0
            case background = 1
        }

        let state: State
        let streamType: StreamType
        /// Raw StreamReason byte: 0 = undefined, 132 = reject background stream.
        /// Other values are retained without assigning undocumented meanings.
        let reason: UInt8

        /// Windows branches on state first: reason132 is a rejection only in
        /// BACKGROUND. A FOREGROUND+A2DP notification can carry the same byte.
        var rejectsBackgroundStream: Bool { state == .background && reason == 132 }

        /// Call classification follows the managed HFP and CIS_CALL flags.
        var isCall: Bool { !streamType.intersection([.hfp, .cisCall]).isEmpty }
    }

    struct Frame: Equatable {
        let command: UInt8
        let payload: Data
        let sequence: UInt8
        let isResponse: Bool
        let isFragment: Bool
    }

    /// Validates one complete legacy SMEP frame; callers must assemble stream
    /// chunks first. This does not interpret a notification as a switch ACK.
    static func decodeCompleteFrame(_ data: Data) -> Frame? {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes.count <= 1027,
              bytes.first == 0xFC, bytes.last == 0xCC, bytes[3] == 0x01 else { return nil }
        let header = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        guard Int(header & 0x03FF) + 4 == bytes.count else { return nil }
        let crcOffset = bytes.count - 3
        let expected = UInt16(bytes[crcOffset]) | UInt16(bytes[crcOffset + 1]) << 8
        guard crc16(Array(bytes[3..<crcOffset])) == expected else { return nil }
        return Frame(command: bytes[4], payload: Data(bytes[5..<crcOffset]),
                     sequence: UInt8(header >> 14), isResponse: header & 0x1000 != 0,
                     isFragment: header & 0x2000 != 0)
    }

    /// EasyConnect2's Buds.AutoSwitchRequestCommand supplies major device class 1.
    /// BudsMsgFmtDynamic.dll RVA 0x1BD0 uses command 0x71 and a one-byte payload.
    static func requestComputerSwitch() -> Data {
        frame(command: 0x71, payload: [0x01])
    }
    /// Windows-builder PHONE=2 variant for an explicit software-role experiment.
    /// Android C102 instead emits an empty payload. Effects need physical proof.
    static func requestMobileCompatibilitySwitch() -> Data {
        frame(command: 0x71, payload: [0x02])
    }

    /// Actual Android MCFDS C102 auto-switch metadata: 02 C1 01 00 maps
    /// to a framed command 0x71 with no payload. Kept separate from the
    /// Windows PHONE=2 builder; this pure reconstruction is not selected
    /// by the packaged controller without a physical compatibility test.
    static func requestAndroidMetadataSwitch() -> Data {
        frame(command: 0x71, payload: [])
    }

    /// MDE_VERSION v3 with the optional account fields unset, as in the inspected
    /// native wrapper. This declares a protocol version; it does not log in.
    /// BudsMsgFmtDynamic.dll RVA 0x1940 constructs this WRITE_PROPERTY TLV.
    static func configureVersion3() -> Data {
        frame(command: 0x43, payload: [0x04, 0x03, 0x07, 0x00, 0x00, 0x0B,
                                       0x03, 0x00, 0x00, 0x00])
    }

    /// Android MCFDS ng.f0.S0 uses k9.a.f8954i = [0, 0, 11], then
    /// [version, 1, ownSHA256[0], ownSHA256[1]]. The account loader stores
    /// SHA256(decoded userFingerprint) in f5876b.f14075b, not a peer hash.
    /// Windows Dynamic RVA 0x1940 confirms the same fixed ten-byte v3 TLV:
    /// presence at offset 7, then hash high/low bytes at offsets 8/9.
    /// Only the framed device packet leaves this pure helper; no diagnostics.
    static func configureOwnedAccountVersion3(accountFingerprint: Data) throws -> Data {
        guard (2...4096).contains(accountFingerprint.count) else { throw Failure.invalidFingerprint }
        let digest = Array(SHA256.hash(data: accountFingerprint).prefix(2))
        return frame(command: 0x43, payload: [0x04, 0x03, 0x07, 0x00, 0x00, 0x0B,
                                              0x03, 0x01, digest[0], digest[1]])
    }
    /// Android ng.f0.S0 writes value 2 when enabled with at most one output,
    /// value 1 with multiple outputs and 0 when disabled. This laboratory
    /// conversion preserves the owned tag; it does not establish that Android's
    /// value has identical semantics to the Windows MDE_VERSION enum.
    static func version2OwnedConfiguration(from configuration: Data) throws -> Data {
        guard let decoded = decodeCompleteFrame(configuration), decoded.command == 0x43 else { throw Failure.invalidOwnedConfiguration }
        var payload = Array(decoded.payload)
        guard payload.count == 10, Array(payload.prefix(8)) == [4, 3, 7, 0, 0, 11, 3, 1] else { throw Failure.invalidOwnedConfiguration }
        payload[6] = 2
        return frame(command: 0x43, payload: payload)
    }

    /// Windows BluetoothClassicConnector.SetAutoSwitchPacket sends this before
    /// MDE v3. DllBudsMsgFmt BuildPacketSettingInfo RVA 0x1230 passes class 1,
    /// constants 4/0/0x75/2A410C and transport BT=1 to Dynamic RVA 0x1CA0.
    /// The latter builds command 0x73 with a 17-byte settings payload. These
    /// compatibility constants are not an account credential or a Mac hardware ID.
    static func settingInfoClassicBluetooth() -> Data {
        frame(command: 0x73, payload: [0x01, 0x01, 0x04, 0x00, 0x01, 0x75, 0x00,
                                       0x2A, 0x41, 0x0C, 0x00, 0x00, 0x00, 0x00,
                                       0x00, 0x00, 0x00])
    }
    /// Recovered 17-byte contract; offset 1 is connection major class. This is
    /// software-role metadata, not a claim of different Mac radio hardware.
    static func settingInfoMobileCompatibilityBluetooth() -> Data {
        frame(command: 0x73, payload: [0x01, 0x02, 0x04, 0x00, 0x01, 0x75, 0x00,
                                       0x2A, 0x41, 0x0C, 0x00, 0x00, 0x00, 0x00,
                                       0x00, 0x00, 0x00])
    }

    /// BudsMsgFmtDynamic.dll RVA 0x1A50: WRITE_PROPERTY, MDE playback opcode 0x0C.
    /// Reports this computer's playback state; does not issue a media command.
    static func playbackStatus(_ status: PlaybackStatus) -> Data {
        frame(command: 0x43, payload: [0x04, 0x03, 0x04, 0x00, 0x00, 0x0C, status.rawValue])
    }

    /// BudsMsgFmtDynamic.dll RVA 0x1B10: WRITE_PROPERTY, output opcode 0x0E.
    static func outputDeviceState(_ state: OutputDeviceState) -> Data {
        frame(command: 0x43, payload: [0x04, 0x03, 0x04, 0x00, 0x00, 0x0E, state.rawValue])
    }

    /// Static reconstruction of the 0x0502 / 0x0B notification contract.
    /// Dynamic RVA 0x1880 supplies each TLV's value to wrapper callbacks at
    /// RVAs 0x15E0, 0x16F0 and 0x1800: minimum 18 bytes, offsets 1, 7 and 2.
    /// Decode/CRC-check frames first. Reject incomplete TLV streams and unknown
    /// states; retain unknown stream/reason bytes. Last qualifying TLV wins,
    /// matching the wrapper callbacks, without retaining state between frames.
    static func multipointStatus(_ frame: Frame) -> MultipointStatus? {
        guard !frame.isFragment, frame.command == 0x44 || frame.command == 0x45 else { return nil }
        let bytes = [UInt8](frame.payload)
        var index = frame.command == 0x44 ? 2 : 0
        guard bytes.count >= index else { return nil }
        var result: MultipointStatus?
        while index < bytes.count {
            guard bytes.count - index >= 3 else { return nil }
            let key = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            let length = Int(bytes[index + 2])
            let value = index + 3
            guard length <= bytes.count - value else { return nil }
            if key == 0x0502, length >= 0x12, bytes[value] == 0x0B {
                result = MultipointStatus.State(rawValue: bytes[value + 1]).map {
                    MultipointStatus(state: $0, streamType: StreamType(rawValue: bytes[value + 7]),
                                     reason: bytes[value + 2])
                }
            }
            index = value + length
        }
        return result
    }

    /// Existing SppAlternativeMessage.ReadPropertyAsync(ALL_CURRENT_STATES).
    static func readCurrentStates() -> Data { frame(command: 0x44, payload: [0x00, 0x02]) }

    /// Existing AltProperty.STATE_SEAMLESS_EARBUD_CONNECTION (531). Read only:
    /// its one-byte value is exposed as raw until its polarity is demonstrated.
    static func readSeamlessConnection() -> Data { frame(command: 0x44, payload: [0x13, 0x02]) }

    /// Diagnostic metadata only. Never retain raw payloads, peer records,
    /// identifiers, account hashes or other property values.
    static func diagnosticSummary(_ frame: Frame) -> [String: Any] {
        var result: [String: Any] = ["command": Int(frame.command),
            "response": frame.isResponse, "payload_length": frame.payload.count]
        if !frame.isFragment, frame.command == 0x42, frame.payload.count == 2 {
            let ack = [UInt8](frame.payload)
            if [UInt8(0x43), 0x44, 0x71, 0x73].contains(ack[0]) {
                result["ack_command"] = Int(ack[0])
                result["ack_value_raw"] = Int(ack[1])
            }
        }
        guard !frame.isFragment, frame.command == 0x44 || frame.command == 0x45 else { return result }
        let bytes = [UInt8](frame.payload)
        var index = frame.command == 0x44 ? 2 : 0
        guard bytes.count >= index else { result["properties_valid"] = false; return result }
        var properties: [[String: Int]] = []
        var seamless: Int?
        var foregroundInfo: (version: Int, majorClass: Int)?
        while index < bytes.count {
            guard bytes.count - index >= 3 else { result["properties_valid"] = false; return result }
            let key = Int(bytes[index]) | Int(bytes[index + 1]) << 8
            let count = Int(bytes[index + 2]), value = index + 3
            guard count <= bytes.count - value else { result["properties_valid"] = false; return result }
            if properties.count < 64 { properties.append(["id": key, "length": count]) }
            if key == 531, count == 1, bytes[value] <= 1 { seamless = Int(bytes[value]) }
            // Android17 MCFDS ga.d.d: TLV value[3] is fgAutoswitchVer and
            // value[4] is fgMajorClass. Adjacent value[5...6] is an account
            // hash and is deliberately never retained by diagnostics.
            if key == 0x0502, count >= 18, bytes[value] == 0x0B {
                foregroundInfo = (Int(bytes[value + 3]), Int(bytes[value + 4]))
            }
            index = value + count
        }
        result["properties_valid"] = true
        result["properties"] = properties
        if let seamless { result["seamless_connection_raw"] = seamless }
        if let status = multipointStatus(frame) {
            result["mde_state"] = Int(status.state.rawValue)
            result["mde_reason"] = Int(status.reason)
            result["mde_stream_flags"] = Int(status.streamType.rawValue)
            if let foregroundInfo {
                result["mde_foreground_version"] = foregroundInfo.version
                result["mde_foreground_major_class"] = foregroundInfo.majorClass
            }
        }
        return result
    }

    /// Same property IDs/TLV layout as the existing alternative-message decoder.
    /// Only battery values leave this parser; account and identity fields are ignored.
    static func batteryProperties(_ frame: Frame) -> [UInt16: Int] {
        guard !frame.isFragment, frame.command == 0x44 || frame.command == 0x45 else { return [:] }
        let bytes = [UInt8](frame.payload)
        var index = frame.command == 0x44 ? 2 : 0
        guard bytes.count >= index else { return [:] }
        var result: [UInt16: Int] = [:]
        while index < bytes.count {
            guard index + 3 <= bytes.count else { return [:] }
            let key = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            let length = Int(bytes[index + 2])
            guard index + 3 + length <= bytes.count else { return [:] }
            if [0x0208, 0x0209, 0x020A].contains(key), length == 1 {
                let value = Int(bytes[index + 3])
                if (1...100).contains(value) { result[key] = value }
            }
            index += 3 + length
        }
        return result
    }

    /// AltProperty.STATE_BINARY_VERSION_STR (535), already supplied by the
    /// ordinary metadata read. Never enter a firmware-transfer session to read it.
    static func firmwareVersion(_ frame: Frame) -> String? {
        guard !frame.isFragment, frame.command == 0x44 || frame.command == 0x45 else { return nil }
        let bytes = [UInt8](frame.payload)
        var index = frame.command == 0x44 ? 2 : 0
        guard bytes.count >= index else { return nil }
        var version: String?
        while index < bytes.count {
            guard index + 3 <= bytes.count else { return nil }
            let key = Int(bytes[index]) | Int(bytes[index + 1]) << 8
            let length = Int(bytes[index + 2]), start = index + 3
            guard length <= bytes.count - start else { return nil }
            if key == 535 {
                let value = Array(bytes[start..<(start + length)])
                guard value.count == 12, value.starts(with: Array("R630".utf8)),
                      value.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
                      let parsed = String(bytes: value, encoding: .ascii), version == nil || version == parsed else { return nil }
                version = parsed
            }
            index = start + length
        }
        return version
    }

    private static func frame(command: UInt8, payload: [UInt8]) -> Data {
        let content: [UInt8] = [0x01, command] + payload
        let size = UInt16(content.count + 2)
        let crc = crc16(content)
        return Data([0xFC, UInt8(truncatingIfNeeded: size), UInt8(size >> 8)]
                    + content
                    + [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8), 0xCC])
    }

    /// CRC-16/CCITT with zero initial value; the frame stores it little-endian.
    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021
            }
        }
        return crc
    }
}
