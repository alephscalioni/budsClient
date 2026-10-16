// SPDX-License-Identifier: GPL-3.0-only
// Wire evidence: GalaxyBudsClient/Message/{Encoder/SetCustomEqualizerEncoder,
// Decoder/CustomEqualizerDataDecoder,Encoder/SetEqualizerEncoder}.cs,
// Interface/ViewModels/Pages/EqualizerPageViewModel.cs and SppMessageEnums.cs.
import Foundation
import CoreFoundation

/// Pure SppNew codecs. These functions do not acquire or authorize a transport.
enum SamsungBudsCustomEqualizer {
    typealias Packet = SamsungBudsSettingsPacket
    static let readCommand: UInt8 = 105
    static let writeCommand: UInt8 = 137
    static let selectionCommand: UInt8 = 134
    static let customSelection: UInt8 = 7 // Original CustomEqPresetIndex (6) + 1.
    static let bandCount = 9
    // The source identifies indices 0...6, but supplies no captured presetCount.
    // Accept only counts within that known domain; never guess a longer table.
    // The original UI ignores readback on Buds4 Pro and displays saved slots.
    // Those slots are not evidence of an actual Buds3 Pro reply in this path.
    static let maximumPresetCount = 7

    struct Curve: Equatable {
        let presetCount: Int
        let bands: [Int]
    }

    static func valid(_ bands: [Int]) -> Bool {
        bands.count == bandCount && bands.allSatisfy { (-10...10).contains($0) }
    }

    static func parseBands(_ value: Any?) -> [Int]? {
        guard let values = value as? [Any], values.count == bandCount else { return nil }
        var bands: [Int] = []
        for value in values {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, (-10.0...10.0).contains(number.doubleValue),
                  number.doubleValue.rounded() == number.doubleValue else { return nil }
            bands.append(number.intValue)
        }
        return bands
    }

    static var readRequest: Data { Packet.frame(command: readCommand, payload: []) }
    static var selectionRequest: Data { Packet.frame(command: selectionCommand, payload: [customSelection]) }
    static func writePayload(_ bands: [Int]) -> [UInt8]? {
        guard valid(bands) else { return nil }
        return [UInt8(bandCount)] + bands.map { UInt8(bitPattern: Int8($0)) }
    }
    static func writeRequest(_ bands: [Int]) -> Data? {
        writePayload(bands).map { Packet.frame(command: writeCommand, payload: $0) }
    }

    static func curve(_ frame: Packet.Frame) -> Curve? {
        guard !frame.isFragment, frame.command == readCommand,
              (2 + bandCount...2 + maximumPresetCount * bandCount).contains(frame.payload.count) else { return nil }
        let bytes = [UInt8](frame.payload) // Also normalizes Data slices.
        let presets = Int(bytes[0]), bands = Int(bytes[1])
        guard (1...maximumPresetCount).contains(presets), bands == bandCount,
              bytes.count == 2 + presets * bands else { return nil }
        // Flat preset zero is OMITTED: skip (presetCount - 1) table rows,
        // then read exactly one custom row. Trailing bytes are never ignored.
        let gains = bytes.dropFirst(2).map { Int(Int8(bitPattern: $0)) }
        guard gains.allSatisfy({ (-10...10).contains($0) }) else { return nil }
        return Curve(presetCount: presets, bands: Array(gains.suffix(bandCount)))
    }

    /// Separate from the base preset 0...5 API and its ACK whitelist. The model
    /// arms this exact echo only after matching readback AND SDK completions.
    static func acknowledgesSelection(_ frame: Packet.Frame) -> Bool {
        !frame.isFragment && frame.command == 0x42
            && frame.payload == Data([selectionCommand, customSelection])
    }

    /// Packet shape only, for the host's independently owned transport whitelist.
    /// It does not authorize selection before a verified custom readback.
    static func permits(_ frame: Packet.Frame) -> Bool {
        guard !frame.isFragment else { return false }
        if frame.command == readCommand { return frame.payload.isEmpty }
        if frame.command == selectionCommand { return frame.payload == Data([customSelection]) }
        guard frame.command == writeCommand, frame.payload.count == bandCount + 1 else { return false }
        let bytes = [UInt8](frame.payload)
        return bytes[0] == UInt8(bandCount) && valid(bytes.dropFirst().map { Int(Int8(bitPattern: $0)) })
    }
}

/// VERSION READ only. SoftwareVersionOtaDecoder consumes the complete ASCII
/// payload of FOTA_DEVICE_INFO_SW_VERSION (0xB4), not a NUL-terminated string.
/// FirmwareRemoteBinary expects 12-character build identities. The native path
/// accepts only an exact uppercase R630 identity; no FOTA session/write is used.
enum SamsungBudsFirmwareVersion {
    typealias Packet = SamsungBudsSettingsPacket
    static let command: UInt8 = 0xB4
    static var request: Data { Packet.frame(command: command, payload: []) }

    static func version(_ frame: Packet.Frame) -> String? {
        guard !frame.isFragment, frame.command == command, frame.payload.count == 12 else { return nil }
        let bytes = [UInt8](frame.payload)
        guard bytes.starts(with: Array("R630".utf8)), bytes.dropFirst(4).allSatisfy({
            (48...57).contains($0) || (65...90).contains($0)
        }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)
    }

    static func permits(_ frame: Packet.Frame) -> Bool {
        !frame.isFragment && frame.command == command && frame.payload.isEmpty
    }
}
