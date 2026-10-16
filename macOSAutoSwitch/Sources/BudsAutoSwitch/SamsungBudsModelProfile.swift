import Foundation

/// Bounded normal-SPP profiles from the pinned ORIGINAL Model/Specifications
/// and Constants.DeviceIds. Newer-model tail layouts are intentionally absent.
enum SamsungBudsModelProfile: String, CaseIterable, Equatable {
    case buds = "Buds", budsPlus = "BudsPlus", budsLive = "BudsLive", budsPro = "BudsPro"
    case buds2 = "Buds2", buds2Pro = "Buds2Pro", budsFe = "BudsFe", budsCore = "BudsCore"
    case buds3 = "Buds3", buds3Pro = "Buds3Pro", buds3Fe = "Buds3Fe", buds4 = "Buds4", buds4Pro = "Buds4Pro"
    typealias Packet = SamsungBudsSettingsPacket

    var serviceUUID: String {
        switch self {
        case .buds: return "00001102-0000-1000-8000-00805f9b34fd"
        case .budsPlus, .budsLive, .budsPro: return "00001101-0000-1000-8000-00805f9b34fb"
        default: return Packet.serviceUUID
        }
    }
    var legacyFraming: Bool { self == .buds }
    /// ModelMetadata.BuildPrefix from the pinned client. Buds FE uses R400N.
    var firmwarePrefix: String {
        switch self {
        case .buds: return "R170"
        case .budsPlus: return "R175"
        case .budsLive: return "R180"
        case .budsPro: return "R190"
        case .buds2: return "R177"
        case .buds2Pro: return "R510"
        case .budsFe: return "R400N"
        case .budsCore: return "R410"
        case .buds3: return "R530"
        case .buds3Pro: return "R630"
        case .buds3Fe: return "R420"
        case .buds4: return "R540"
        case .buds4Pro: return "R640"
        }
    }
    var title: String {
        switch self {
        case .buds: return "Galaxy Buds"
        case .budsPlus: return "Galaxy Buds+"
        case .budsLive: return "Galaxy Buds Live"
        case .budsPro: return "Galaxy Buds Pro"
        case .buds2: return "Galaxy Buds2"
        case .buds2Pro: return "Galaxy Buds2 Pro"
        case .budsFe: return "Galaxy Buds FE"
        case .budsCore: return "Galaxy Buds Core"
        case .buds3: return "Galaxy Buds3"
        case .buds3Pro: return "Galaxy Buds3 Pro"
        case .buds3Fe: return "Galaxy Buds3 FE"
        case .buds4: return "Galaxy Buds4"
        case .buds4Pro: return "Galaxy Buds4 Pro"
        }
    }
    var colorIDs: Set<Int> {
        switch self {
        case .buds: return [257, 14336] // Original status has no color-ID fields.
        case .budsPlus: return Set(258...266)
        case .budsLive: return Set(278...284)
        case .budsPro: return Set(298...301)
        case .buds2: return Set(313...321).union([14337])
        case .buds2Pro: return Set(325...328)
        case .budsFe: return [330, 331]
        case .budsCore: return [322, 323]
        case .buds3: return [333, 334]
        case .buds3Pro: return [340, 341]
        case .buds3Fe: return [347, 348]
        case .buds4: return [355, 356]
        case .buds4Pro: return [359, 360, 361]
        }
    }
    var noiseModes: [Packet.NoiseMode] {
        switch self {
        case .buds, .budsPlus: return [.off, .ambient]
        case .budsLive: return [.off, .anc]
        case .buds3Pro, .buds4Pro: return [.off, .anc, .ambient, .adaptive]
        default: return [.off, .anc, .ambient]
        }
        // Buds3 Pro adaptive is independently verified by the Samsung APK protocol.
    }
    var supportsCustomEqualizer: Bool { [.buds3, .buds3Pro, .buds3Fe, .buds4, .buds4Pro].contains(self) }
    var supportsFitTest: Bool { ![.buds, .budsPlus, .budsLive, .budsPro].contains(self) }
    // Normal A0/A1/A2 family is unconditional in FindMyBudsPageViewModel;
    // FmgRingWhileWearing only changes the start command to A6.
    var supportsFind: Bool { true }
    var supportsInfo: Bool { self != .buds } // VERSION_INFO / DEBUG_SERIAL_NUMBER are unconditional.
    var supportsTenByteTouch: Bool { [.buds3Pro, .buds4, .buds4Pro].contains(self) }

    static func physical(_ frame: Packet.Frame, model: String) -> Bool? {
        guard let profile = Self(rawValue: model), !frame.isFragment, frame.command == 0x61 else { return nil }
        if profile == .buds { return frame.legacyFraming && frame.payload.count >= 13 ? true : nil }
        guard !frame.legacyFraming else { return false }
        let offset = profile == .budsPlus ? 15 : 14
        let p = Array(frame.payload)
        guard p.count >= offset + 4 else { return nil }
        let ids = [Int(p[offset]) | Int(p[offset + 1]) << 8, Int(p[offset + 2]) | Int(p[offset + 3]) << 8]
        if ids.contains(where: { $0 != 0 && !profile.colorIDs.contains($0) }) { return false }
        return ids.allSatisfy(profile.colorIDs.contains) ? true : nil
    }
    static func identify(_ frame: Packet.Frame, expected: Self? = nil) -> Self? {
        if frame.legacyFraming {
            return expected == .buds && physical(frame, model: Self.buds.rawValue) == true ? .buds : nil
        }
        let matches = allCases.filter { $0 != .buds && physical(frame, model: $0.rawValue) == true }
        guard matches.count == 1, let match = matches.first, expected == nil || expected == match else { return nil }
        return match
    }
    static func resolve(model: String?, name: String) -> Self? {
        func alias(_ value: String) -> Self? {
            let key = value.lowercased().replacingOccurrences(of: "galaxy", with: "")
                .replacingOccurrences(of: "+", with: "plus").filter { $0.isLetter || $0.isNumber }
            return allCases.first { $0.rawValue.lowercased() == key }
        }
        if let model, !model.isEmpty { return alias(model) }
        let name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let family = name.hasPrefix("galaxy ") ? String(name.dropFirst(7)) : name
        // Longest family first. A digit/letter after a prefix cannot select a
        // previous generation (Buds4 must never resolve as Buds or Buds3 Pro).
        for profile in allCases.reversed() {
            let base = profile.title.lowercased().replacingOccurrences(of: "galaxy ", with: "")
            let variants = [base, base.replacingOccurrences(of: "buds", with: "buds ")]
            for prefix in variants where family.hasPrefix(prefix) {
                if profile == .buds && family.hasPrefix(prefix + " de ") { continue }
                let suffix = String(family.dropFirst(prefix.count))
                if suffix.isEmpty || suffix.hasPrefix(" (") || suffix.hasPrefix(" -") || suffix.hasPrefix("'") || suffix.hasPrefix(" de ") || suffix.hasPrefix(" of ") { return profile }
            }
        }
        return nil
    }

    /// Shape/capability gate only. The owner still enforces freshness, placement,
    /// authorization and observed physical identity before executing a request.
    func allows(command: UInt8, payload: [UInt8], status: Packet.Status?) -> Bool {
        if let level = Packet.Level.forCommand(command) {
            return payload.count == 1 && status.map { $0.model == rawValue && level.accepts(Int(payload[0]), status: $0) } == true
        }
        if let setting = Packet.Setting.forCommand(command) {
            return status?.model == rawValue && status?.settings[setting] != nil
                && payload.count == 1 && setting.values.contains(Int(payload[0]))
        }
        switch command {
        case 0x61: return payload.isEmpty
        case 0x78: return ![.buds, .budsPlus, .budsLive].contains(self)
            && payload.count == 1 && noiseModes.contains(where: { $0.rawValue == payload[0] })
        case 0x80: return [.buds, .budsPlus].contains(self) && payload.count == 1 && payload[0] <= 1
        case 0x98: return self == .budsLive && payload.count == 1 && payload[0] <= 1
        case 0x86:
            if self == .buds { return payload.count == 2 && payload[0] <= 1 && (5...9).contains(payload[1]) }
            return payload.count == 1 && ((0...6).contains(payload[0]) || (payload[0] == 7 && supportsCustomEqualizer))
        case 0x69: return supportsCustomEqualizer && payload.isEmpty
        case 0x89: return supportsCustomEqualizer && payload.count == 10 && payload[0] == 9
            && payload.dropFirst().allSatisfy { (-10...10).contains(Int(Int8(bitPattern: $0))) }
        case 0x90:
            guard status?.model == rawValue, let status, let touch = status.touchControls,
                  touch.wireLength == touchPayloadLength(revision: status.revision) else { return false }
            return payload == touch.payload(enabled: true) || payload == touch.payload(enabled: false)
                || payload == touch.mediaPayload(enabled: true) || payload == touch.mediaPayload(enabled: false)
                || touch.admitsIndividualUpdate(payload)
        case 0x9D: return supportsFitTest && payload.count == 1 && payload[0] <= 1
        case 0xA0, 0xA1: return supportsFind && payload.isEmpty
        case 0xA2: return supportsFind && payload.count == 2 && payload.allSatisfy { $0 <= 1 }
        case 0xA6: return supportsFind && ![.buds, .budsPlus, .budsLive, .budsPro].contains(self)
            && payload.isEmpty && status?.model == rawValue
            && (self != .buds2 || (status?.revision ?? -1) >= 9)
            && (self != .buds2Pro || (status?.revision ?? -1) >= 4)
        case 0x63, 0x29, 0x26: return supportsInfo && payload.isEmpty
        case 0x22: return ![.buds, .budsPlus].contains(self) && payload.isEmpty // DEBUG_SKU
        case 0x28: return [.buds, .budsPlus, .budsLive, .budsPro].contains(self) && payload.isEmpty
        case 0x94: return self == .buds && payload.isEmpty
        case 0xB4: return self != .buds && payload.isEmpty
            && (self != .budsPlus || (status?.model == rawValue && (status?.revision ?? -1) >= 8))
        default: return false
        }
    }
}
