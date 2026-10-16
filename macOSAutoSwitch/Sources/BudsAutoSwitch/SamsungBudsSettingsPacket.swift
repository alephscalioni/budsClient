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
        /// Set only by the legacy FE/type/size/EE decoder; callers propagating
        /// decoded frames must preserve this metadata.
        let legacyFraming: Bool
        init(command: UInt8, payload: Data, isFragment: Bool, legacyFraming: Bool = false) {
            self.command = command; self.payload = payload; self.isFragment = isFragment
            self.legacyFraming = legacyFraming
        }
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
        let wireLength: Int
        let forcesHoldEnabled: Bool

        init?(bitfield: UInt8, lightingControl: UInt8? = nil, doublePinchAndHold: UInt8? = nil, wireLength: Int = 10, forcesHoldEnabled: Bool = true) {
            guard [5, 7, 10].contains(wireLength), wireLength != 10 || (lightingControl != nil && doublePinchAndHold != nil) else { return nil }
            self.wireLength = wireLength
            self.forcesHoldEnabled = wireLength == 10 && forcesHoldEnabled
            let lightingControl = lightingControl ?? 0, doublePinchAndHold = doublePinchAndHold ?? 0
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
            Array(([enabled, tap, doubleTap, tripleTap, hold, callDoubleTap, callHold, swipe].map { UInt8($0 ? 1 : 0) }
                + [lightingControl, doublePinchAndHold]).prefix(wireLength))
        }

        var fields: [String: Bool] {
            let parameters = payload(enabled: enabled)
            return Dictionary(uniqueKeysWithValues: Gesture.allCases.filter { $0.parameterIndex < min(wireLength, 8) }.map { ($0.rawValue, parameters[$0.parameterIndex] == 1) })
        }
        func payload(changing gesture: Gesture, enabled value: Bool) -> [UInt8] {
            var parameters = payload(enabled: enabled)
            guard gesture.parameterIndex < parameters.count else { return parameters }
            parameters[gesture.parameterIndex] = value ? 1 : 0
            // Buds3 Pro TouchControlsActivity.T enables hold with every change.
            // The Buds4 producer instead preserves the observed hold flag.
            if forcesHoldEnabled { parameters[4] = 1 }
            return parameters
        }
        func admitsIndividualUpdate(_ parameters: [UInt8]) -> Bool {
            guard parameters.count == wireLength else { return false }
            return Gesture.allCases.filter { $0.parameterIndex < min(wireLength, 8) }.contains { gesture in
                payload(changing: gesture, enabled: parameters[gesture.parameterIndex] == 1) == parameters
            }
        }
        func replacing(with parameters: [UInt8]) -> TouchControls? {
            guard parameters.count == wireLength, parameters.prefix(min(8, wireLength)).allSatisfy({ $0 <= 1 }) else { return nil }
            let masks: [UInt8] = [0x80, 0x08, 0x04, 0x02, 0x01, 0x10, 0x20, 0x40]
            let bitfield = zip(parameters.prefix(8), masks).reduce(UInt8(0)) { $0 | ($1.0 == 1 ? $1.1 : 0) }
            return TouchControls(bitfield: bitfield, lightingControl: parameters.count == 10 ? parameters[8] : nil,
                doublePinchAndHold: parameters.count == 10 ? parameters[9] : nil, wireLength: wireLength,
                forcesHoldEnabled: forcesHoldEnabled)
        }

        /// Samsung z9.t media switch changes pinch/double/triple/swipe;
        /// TouchControlsActivity.T keeps hold on and preserves master, calls
        /// and the two type bytes. This is distinct from the global master.
        var mediaEnabled: Bool? {
            let values = wireLength == 10 ? [tap, doubleTap, tripleTap, swipe] : [tap, doubleTap, tripleTap]
            return values.allSatisfy { $0 } ? true : values.allSatisfy { !$0 } ? false : nil
        }
        func mediaPayload(enabled media: Bool) -> [UInt8] {
            Array(([enabled, media, media, media, forcesHoldEnabled ? true : hold, callDoubleTap, callHold, media].map { UInt8($0 ? 1 : 0) }
                + [lightingControl, doublePinchAndHold]).prefix(wireLength))
        }
    }

    struct Status: Equatable {
        var model: String = "Buds3Pro"
        var revision: Int = 0
        var levels: [Level: Int] = [:]
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

    // Preserve the one-argument function value used by existing map/compactMap
    // callers; Swift default arguments do not preserve a function's arity.
    static func decodeCompleteFrame(_ data: Data) -> Frame? { decodeCompleteFrame(data, profile: nil) }

    static func decodeCompleteFrame(_ data: Data, profile: SamsungBudsModelProfile? = nil) -> Frame? {
        let b = [UInt8](data)
        let legacy = profile?.legacyFraming == true
        guard (7...(legacy ? 259 : 1027)).contains(b.count),
              b.first == (legacy ? 0xFE : 0xFD), b.last == (legacy ? 0xEE : 0xDD) else { return nil }
        let header = UInt16(b[1]) | UInt16(b[2]) << 8
        if legacy {
            guard b[1] <= 1, Int(b[2]) + 4 == b.count else { return nil }
        } else {
            guard Int(header & 0x03FF) + 4 == b.count else { return nil }
        }
        let end = b.count - 3
        let crc = UInt16(b[end]) | UInt16(b[end + 1]) << 8
        guard SamsungMdePacket.crc16(Array(b[3..<end])) == crc else { return nil }
        return Frame(command: b[3], payload: Data(b[4..<end]), isFragment: !legacy && header & 0x2000 != 0, legacyFraming: legacy)
    }

    static func frame(command: UInt8, payload: [UInt8], profile: SamsungBudsModelProfile? = nil) -> Data {
        // Only bounded settings payloads are constructed by this backend.
        let legacy = profile?.legacyFraming == true
        precondition(payload.count <= (legacy ? 252 : 1020))
        let content = [command] + payload
        let size = UInt16(content.count + 2)
        let crc = SamsungMdePacket.crc16(content)
        let header: [UInt8] = legacy ? [0xFE, 0, UInt8(size)]
            : [0xFD, UInt8(truncatingIfNeeded: size), UInt8(size >> 8)]
        return Data(header + content + [UInt8(truncatingIfNeeded: crc), UInt8(crc >> 8), legacy ? 0xEE : 0xDD])
    }

    /// Exact selected model is a prerequisite. No offsets for other generations
    /// are guessed. Invalid individual readings stay unknown, independently.
    static func physicalBuds3Pro(_ frame: Frame) -> Bool? {
        SamsungBudsModelProfile.physical(frame, model: "Buds3Pro")
    }

    static func status(_ frame: Frame, model: String = "Buds3Pro") -> Status? {
        guard let profile = SamsungBudsModelProfile(rawValue: model),
              SamsungBudsModelProfile.physical(frame, model: model) != false,
              frame.legacyFraming == profile.legacyFraming, !frame.isFragment, frame.command == 0x61,
              frame.payload.count <= 1020 else { return nil }
        let p = [UInt8](frame.payload)
        let minimum = profile == .buds ? 13 : profile == .budsPlus ? 19 : profile == .budsLive ? 18 : 25
        guard p.count >= minimum else { return nil }
        let leftPlacement: Placement, rightPlacement: Placement
        if profile == .buds {
            guard [UInt8(0), 1, 16, 17].contains(p[6]) else { return nil }
            leftPlacement = p[6] & 16 != 0 ? .wearing : .idle
            rightPlacement = p[6] & 1 != 0 ? .wearing : .idle
        } else {
            guard let left = Placement(rawValue: p[6] >> 4), let right = Placement(rawValue: p[6] & 15) else { return nil }
            leftPlacement = left; rightPlacement = right
        }
        func percent(_ value: UInt8) -> Int? { value <= 100 ? Int(value) : nil }
        let noise: NoiseMode?
        let eq: UInt8, ambient: Int, touchEnabled: Bool
        switch profile {
        case .buds:
            noise = p[7] <= 1 ? (p[7] == 1 ? .ambient : .off) : nil
            let preset = p[11] <= 4 ? p[11] : (5...9).contains(p[11]) ? p[11] - 5 : 255
            // Canonical modern UI indices: flat=0, five original presets=1...5.
            eq = p[10] == 0 ? 1 : p[10] == 1 && preset <= 4 ? preset + 2 : 255
            ambient = Int(p[9])
            touchEnabled = p[12] == 0
        case .budsPlus:
            noise = p[8] <= 1 ? (p[8] == 1 ? .ambient : .off) : nil
            eq = p[11]; ambient = Int(p[9]); touchEnabled = p[12] == 0
        case .budsLive:
            noise = p[12] <= 1 ? (p[12] == 1 ? .anc : .off) : nil
            eq = p[9]; ambient = 0; touchEnabled = p[10] == 0
        default:
            noise = NoiseMode(rawValue: p[12]).flatMap { profile.noiseModes.contains($0) ? $0 : nil }
            eq = p[9]; ambient = Int(p[23])
            touchEnabled = profile == .budsPro || (profile == .buds2 && p[0] < 4) ? p[10] == 0 : p[10] & 0x80 != 0
        }
        return Status(model: model, revision: Int(p[0]), levels: Level.observed(p, model: model), left: percent(p[2]), right: percent(p[3]),
            casePercent: profile == .buds ? nil : percent(p[7]), noise: noise, rawEqualizer: eq,
            ambientLevel: ambient, touchEnabled: touchEnabled,
            touchControls: touchControls(p, profile: profile),
            physicalModelVerified: SamsungBudsModelProfile.physical(frame, model: model) == true,
            settings: Setting.observed(p, model: model), leftPlacement: leftPlacement, rightPlacement: rightPlacement)
    }

    private static func touchControls(_ payload: [UInt8], profile: SamsungBudsModelProfile) -> TouchControls? {
        guard let length = profile.touchPayloadLength(revision: Int(payload[0])) else { return nil }
        if profile == .buds4 || profile == .buds4Pro {
            // Samsung budsUnite kk.f SET_EARBUDS_CONTROL: eight observed
            // flags followed by fixed1,1. These are not Buds3 Pro tail offsets.
            return TouchControls(bitfield: payload[10], lightingControl: 1, doublePinchAndHold: 1, forcesHoldEnabled: false)
        }
        if length == 10 {
            guard payload.count >= 53 else { return nil }
            return TouchControls(bitfield: payload[10], lightingControl: payload[51], doublePinchAndHold: payload[52])
        }
        return TouchControls(bitfield: payload[10], wireLength: length)
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
    static func acknowledges(_ frame: Frame, command: UInt8, payload: [UInt8], profile: SamsungBudsModelProfile? = nil) -> Bool {
        guard !frame.isFragment, frame.command == 0x42 else { return false }
        switch command {
        case 0x83, 0x84: guard payload.count == 1, payload[0] <= 4 else { return false }
        case 0x78: guard payload.count == 1, NoiseMode(rawValue: payload[0]) != nil else { return false }
        case 0x80, 0x98: guard payload.count == 1, payload[0] <= 1 else { return false }
        case 0x86:
            if profile == .buds {
                guard payload.count == 2, payload[0] <= 1, (5...9).contains(payload[1]) else { return false }
            } else { guard payload.count == 1, (1...6).contains(payload[0]) else { return false } }
        case 0x90: guard [5, 7, 10].contains(payload.count), payload.prefix(min(8, payload.count)).allSatisfy({ $0 <= 1 }) else { return false }
        default:
            guard let setting = Setting.forCommand(command), payload.count == 1,
                  setting.values.contains(Int(payload[0])) else { return false }
        }
        return [UInt8](frame.payload) == [command] + payload
    }

    struct Stream {
        private let profile: SamsungBudsModelProfile?
        init(profile: SamsungBudsModelProfile? = nil) { self.profile = profile }
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
                let legacy = profile?.legacyFraming == true
                guard buffer.first == (legacy ? 0xFE : 0xFD) else { buffer.removeFirst(); discarded += 1; continue }
                guard buffer.count >= 3 else { break }
                let p = Array(buffer.prefix(3))
                let size = legacy ? Int(p[2]) + 4 : Int((UInt16(p[1]) | UInt16(p[2]) << 8) & 0x03FF) + 4
                guard (7...(legacy ? 259 : 1027)).contains(size), !legacy || p[1] <= 1 else { buffer.removeFirst(); discarded += 1; continue }
                guard buffer.count >= size else { break }
                guard let frame = decodeCompleteFrame(Data(buffer.prefix(size)), profile: profile) else {
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
