import Foundation

/// Normal SppNew, NOT the SMEP envelope. Wire anchors: Tools/BudsSettingsProbe,
/// SppMessage.Encode, ExtendedStatusUpdateDecoder (>= BudsLive common prefix).
enum SamsungBudsSettingsPacket {
    static let serviceUUID = "2e73a4ad-332d-41fc-90e2-16bef06523f2"

    enum NoiseMode: UInt8, CaseIterable {
        case off = 0, anc = 1, ambient = 2, adaptive = 3
        var name: String {
            switch self {
            case .off: return "off"
            case .anc: return "anc"
            case .ambient: return "ambient"
            case .adaptive: return "adaptive"
            }
        }
        init?(name: String) {
            guard let mode = Self.allCases.first(where: { $0.name == name }) else { return nil }
            self = mode
        }
    }

    struct Frame: Equatable {
        let command: UInt8
        let payload: Data
        let isFragment: Bool
    }

    /// Buds3 Pro APK f8.z.b: eight booleans then lighting / advanced-hold
    /// types. Its boolean constructor preserves every field from device state.
    /// f8.n reads the types at 51/52; f8.d0.f consumes the complete ten-byte echo.
    enum Gesture: String, CaseIterable {
        case singlePinch = "single_pinch", doublePinch = "double_pinch", triplePinch = "triple_pinch"
        case swipe, callDoublePinch = "call_double_pinch", callHold = "call_hold"
        var parameterIndex: Int {
            switch self {
            case .singlePinch: return 1
            case .doublePinch: return 2
            case .triplePinch: return 3
            case .swipe: return 7
            case .callDoublePinch: return 5
            case .callHold: return 6
            }
        }
    }
    struct TouchControls: Equatable {
        let enabled: Bool
        let tap: Bool
        let doubleTap: Bool
        let tripleTap: Bool
        let hold: Bool
        let callDoubleTap: Bool
        let callHold: Bool
        let swipe: Bool
        let lightingControl: UInt8
        let doublePinchAndHold: UInt8

        init?(bitfield: UInt8, lightingControl: UInt8? = nil, doublePinchAndHold: UInt8? = nil) {
            guard let lightingControl, let doublePinchAndHold else { return nil }
            self.lightingControl = lightingControl; self.doublePinchAndHold = doublePinchAndHold
            swipe = bitfield & 0x40 != 0
            enabled = bitfield & 0x80 != 0
            tap = bitfield & 0x08 != 0
            doubleTap = bitfield & 0x04 != 0
            tripleTap = bitfield & 0x02 != 0
            hold = bitfield & 0x01 != 0
            callDoubleTap = bitfield & 0x10 != 0
            callHold = bitfield & 0x20 != 0
        }

        func payload(enabled: Bool) -> [UInt8] {
            [enabled, tap, doubleTap, tripleTap, hold, callDoubleTap, callHold, swipe].map { $0 ? 1 : 0 }
                + [lightingControl, doublePinchAndHold]
        }

        var fields: [String: Bool] {
            let parameters = payload(enabled: enabled)
            return Dictionary(uniqueKeysWithValues: Gesture.allCases.map { ($0.rawValue, parameters[$0.parameterIndex] == 1) })
        }
        func payload(changing gesture: Gesture, enabled value: Bool) -> [UInt8] {
            var parameters = payload(enabled: enabled)
            parameters[gesture.parameterIndex] = value ? 1 : 0
            // Samsung TouchControlsActivity.T applies this rule to each media
            // and call switch as well as the grouped media operation.
            parameters[4] = 1
            return parameters
        }
        func admitsIndividualUpdate(_ parameters: [UInt8]) -> Bool {
            guard parameters.count == 10 else { return false }
            return Gesture.allCases.contains { gesture in
                payload(changing: gesture, enabled: parameters[gesture.parameterIndex] == 1) == parameters
            }
        }
        func replacing(with parameters: [UInt8]) -> TouchControls? {
            guard parameters.count == 10, parameters.prefix(8).allSatisfy({ $0 <= 1 }) else { return nil }
            let masks: [UInt8] = [0x80, 0x08, 0x04, 0x02, 0x01, 0x10, 0x20, 0x40]
            let bitfield = zip(parameters.prefix(8), masks).reduce(UInt8(0)) { $0 | ($1.0 == 1 ? $1.1 : 0) }
            return TouchControls(bitfield: bitfield, lightingControl: parameters[8], doublePinchAndHold: parameters[9])
        }

        /// Samsung z9.t media switch changes pinch/double/triple/swipe;
        /// TouchControlsActivity.T keeps hold on and preserves master, calls
        /// and the two type bytes. This is distinct from the global master.
        var mediaEnabled: Bool? {
            let values = [tap, doubleTap, tripleTap, swipe]
            return values.allSatisfy { $0 } ? true : values.allSatisfy { !$0 } ? false : nil
        }
        func mediaPayload(enabled media: Bool) -> [UInt8] {
            [enabled, media, media, media, true, callDoubleTap, callHold, media].map { $0 ? 1 : 0 }
                + [lightingControl, doublePinchAndHold]
        }
    }

    struct Status: Equatable {
        let left: Int?
        let right: Int?
        let casePercent: Int?
        let noise: NoiseMode?
        /// Raw zero means EQ disabled; raw 1...6 map to UI 0...5.
        let rawEqualizer: UInt8
        var equalizer: Int? { (1...6).contains(rawEqualizer) ? Int(rawEqualizer) - 1 : nil }
        let ambientLevel: Int
        let touchEnabled: Bool
        let touchControls: TouchControls?
        let physicalModelVerified: Bool
        let settings: [Setting: Int]
        let leftPlacement: Placement
        let rightPlacement: Placement
        var wearingBoth: Bool { leftPlacement == .wearing && rightPlacement == .wearing }
        var bothOutside: Bool { leftPlacement == .idle && rightPlacement == .idle }
    }

    /// Constants.PlacementStates and Samsung f8.n, payload byte6 high/low.
    enum Placement: UInt8 {
        case disconnected = 0, wearing = 1, idle = 2, inCase = 3, closedCase = 4
        var name: String {
            switch self {
            case .disconnected: return "disconnected"
            case .wearing: return "wearing"
            case .idle: return "outside"
            case .inCase: return "case"
            case .closedCase: return "closed_case"
            }
        }
    }

    static func decodeCompleteFrame(_ data: Data) -> Frame? {
        let b = [UInt8](data)
        guard (7...1027).contains(b.count), b.first == 0xFD, b.last == 0xDD else { return nil }
        let header = UInt16(b[1]) | UInt16(b[2]) << 8
        guard Int(header & 0x03FF) + 4 == b.count else { return nil }
        let end = b.count - 3
        let crc = UInt16(b[end]) | UInt16(b[end + 1]) << 8
        guard SamsungMdePacket.crc16(Array(b[3..<end])) == crc else { return nil }
        return Frame(command: b[3], payload: Data(b[4..<end]), isFragment: header & 0x2000 != 0)
    }

    static func frame(command: UInt8, payload: [UInt8]) -> Data {
        // Only bounded settings payloads are constructed by this backend.
        precondition(payload.count <= 1020)
        let content = [command] + payload
        let size = UInt16(content.count + 2)
        let crc = SamsungMdePacket.crc16(content)
        return Data([0xFD, UInt8(truncatingIfNeeded: size), UInt8(size >> 8)] + content
            + [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8), 0xDD])
    }

    /// Exact selected model is a prerequisite. No offsets for other generations
    /// are guessed. Invalid individual readings stay unknown, independently.
    static func physicalBuds3Pro(_ frame: Frame) -> Bool? {
        guard !frame.isFragment, frame.command == 0x61, frame.payload.count >= 18 else { return nil }
        let p = Array(frame.payload)
        let colors = [Int(p[14]) | Int(p[15]) << 8, Int(p[16]) | Int(p[17]) << 8]
        // Zero is unspecified. An explicit different color/model must not be
        // overruled by the personalized paired name or a presentation cache.
        if colors.contains(where: { $0 != 0 && ![340, 341].contains($0) }) { return false }
        return colors.allSatisfy { [340, 341].contains($0) } ? true : nil
    }

    static func status(_ frame: Frame, model: String) -> Status? {
        guard model == "Buds3Pro", physicalBuds3Pro(frame) != false, !frame.isFragment, frame.command == 0x61,
              (25...1020).contains(frame.payload.count) else { return nil }
        let p = [UInt8](frame.payload)
        // PlacementStates on the wire: disconnected/wearing/idle/case/closed.
        guard p[6] >> 4 <= 4, p[6] & 0x0F <= 4 else { return nil }
        func percent(_ value: UInt8) -> Int? { value <= 100 ? Int(value) : nil }
        return Status(left: percent(p[2]), right: percent(p[3]), casePercent: percent(p[7]),
            noise: NoiseMode(rawValue: p[12]), rawEqualizer: p[9], ambientLevel: Int(p[23]),
            touchEnabled: p[10] & 0x80 != 0, touchControls: (1...4).contains(p[0]) && p.count >= 53
                ? TouchControls(bitfield: p[10], lightingControl: p[51], doublePinchAndHold: p[52]) : nil,
            physicalModelVerified: physicalBuds3Pro(frame) == true,
            settings: Setting.observed(p), leftPlacement: Placement(rawValue: p[6] >> 4)!,
            rightPlacement: Placement(rawValue: p[6] & 0x0F)!)
    }

    static func noiseUpdate(_ frame: Frame) -> NoiseMode? {
        guard !frame.isFragment, frame.command == 0x77, (1...2).contains(frame.payload.count) else { return nil }
        let p = [UInt8](frame.payload)
        // Optional LegacyWearStates from NoiseControlUpdateDecoder/Constants.
        guard p.count == 1 || [UInt8(0), 1, 16, 17].contains(p[1]) else { return nil }
        return NoiseMode(rawValue: p[0])
    }

    /// ACK is an echo of the command's parameters, not a status/success code.
    /// For touch, compare ALL ten bytes, including swipe and both type bytes.
    static func acknowledges(_ frame: Frame, command: UInt8, payload: [UInt8]) -> Bool {
        guard !frame.isFragment, frame.command == 0x42 else { return false }
        switch command {
        case 0x78: guard payload.count == 1, NoiseMode(rawValue: payload[0]) != nil else { return false }
        case 0x86: guard payload.count == 1, (1...6).contains(payload[0]) else { return false }
        case 0x90: guard payload.count == 10, payload.prefix(8).allSatisfy({ $0 <= 1 }) else { return false }
        default:
            guard let setting = Setting.forCommand(command), payload.count == 1,
                  setting.values.contains(Int(payload[0])) else { return false }
        }
        return [UInt8](frame.payload) == [command] + payload
    }

    struct Stream {
        private(set) var buffer = Data()
        private var partialSince: TimeInterval?
        private var discarded = 0
        private(set) var fragmentCount = 0

        mutating func append(_ data: Data, at now: TimeInterval) throws -> [Frame] {
            guard now.isFinite, data.count <= 4096, buffer.count + data.count <= 8192 else {
                throw NativeBudsError(message: "Fluxo SppNew excedeu o limite seguro.")
            }
            if let partialSince, now < partialSince || now - partialSince >= 2 {
                buffer.removeAll(); self.partialSince = nil
            }
            buffer.append(data)
            var frames: [Frame] = []
            while !buffer.isEmpty {
                guard buffer.first == 0xFD else { buffer.removeFirst(); discarded += 1; continue }
                guard buffer.count >= 3 else { break }
                let p = Array(buffer.prefix(3))
                let size = Int((UInt16(p[1]) | UInt16(p[2]) << 8) & 0x03FF) + 4
                guard (7...1027).contains(size) else { buffer.removeFirst(); discarded += 1; continue }
                guard buffer.count >= size else { break }
                guard let frame = decodeCompleteFrame(Data(buffer.prefix(size))) else {
                    buffer.removeFirst(); discarded += 1; continue
                }
                buffer.removeFirst(size)
                // Do not interpret a fragment as a complete status or ACK.
                if frame.isFragment { fragmentCount += 1 } else { frames.append(frame) }
                discarded = 0; partialSince = nil
            }
            guard discarded <= 32768 else { throw NativeBudsError(message: "Fluxo SppNew sem quadros válidos.") }
            if buffer.isEmpty { partialSince = nil }
            else if partialSince == nil { partialSince = now }
            return frames
        }
    }
}
