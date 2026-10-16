import Foundation

/// Explicit, bounded SppNew tools. No factory reset or firmware commands.
/// Find uses Buds3 Pro's original A6 route with stricter neither-worn gates.
/// Anchors: SppMessageEnums, FitTestDecoder,
/// MuteEarbudAckParameter and Samsung FitTestActivity.V.
enum NativeBudsToolsPacket {
    // Samsung RingManager.b schedules its host-side stop at 180000 ms.
    static let findDuration: TimeInterval = 180
    typealias Packet = SamsungBudsSettingsPacket
    enum Target: String, CaseIterable { case both, left, right
        var mute: [UInt8] { switch self { case .both: return [0, 0]; case .left: return [0, 1]; case .right: return [1, 0] } }
    }
    enum Fit: UInt8 { case bad = 0, good = 1, failed = 2
        var name: String { switch self { case .bad: return "bad"; case .good: return "good"; case .failed: return "failed" } }
    }
    struct FitResult: Equatable {
        let left: Fit
        let right: Fit
        var fields: [String: String] { ["left": left.name, "right": right.name] }
    }
    static func permits(_ frame: Packet.Frame) -> Bool {
        guard !frame.isFragment else { return false }
        switch frame.command {
        case 0x9D: return frame.payload.count == 1 && frame.payload[0] <= 1
        case 0xA6, 0xA1: return frame.payload.isEmpty
        case 0xA2: return frame.payload.count == 2 && frame.payload.allSatisfy { $0 <= 1 }
        default: return false
        }
    }
    static func fitResult(_ frame: Packet.Frame) -> FitResult? {
        guard !frame.isFragment, frame.command == 0x9E, frame.payload.count == 2,
              let left = Fit(rawValue: frame.payload[0]), let right = Fit(rawValue: frame.payload[1]) else { return nil }
        return .init(left: left, right: right)
    }
    static func stopped(_ frame: Packet.Frame) -> Bool {
        // Both source receivers recognize ID A1 without interpreting payload.
        !frame.isFragment && frame.command == 0xA1
    }
    static func muteConfirmed(_ frame: Packet.Frame, parameters: [UInt8]) -> Bool {
        guard parameters.count == 2, parameters.allSatisfy({ $0 <= 1 }), !frame.isFragment else { return false }
        return (frame.command == 0x42 && Array(frame.payload) == [0xA2] + parameters)
            || (frame.command == 0xA3 && Array(frame.payload) == parameters)
    }
    static func placements(_ frame: Packet.Frame) -> (Packet.Placement, Packet.Placement)? {
        guard !frame.isFragment, let revision = frame.payload.first else { return nil }
        let offset: Int
        switch frame.command {
        case 0x60: guard revision <= 4 else { return nil }; offset = 5
        case 0x61: guard (1...4).contains(revision) else { return nil }; offset = 6
        default: return nil
        }
        guard frame.payload.count > offset,
              let left = Packet.Placement(rawValue: frame.payload[offset] >> 4),
              let right = Packet.Placement(rawValue: frame.payload[offset] & 15) else { return nil }
        return (left, right)
    }
    static func startAllowed(_ frame: Packet.Frame, placements: (Packet.Placement, Packet.Placement)?,
                             observedAt: TimeInterval?, now: TimeInterval) -> Bool {
        if frame.command == 0xA1 || (frame.command == 0x9D && Array(frame.payload) == [0]) { return true }
        guard let placements, let observedAt, now.isFinite, observedAt.isFinite,
              now >= observedAt, now - observedAt <= 5 else { return false }
        if frame.command == 0xA6 || frame.command == 0xA2 {
            return placements.0 == .idle && placements.1 == .idle
        }
        if frame.command == 0x9D && Array(frame.payload) == [1] {
            return placements.0 == .wearing && placements.1 == .wearing
        }
        return true
    }
}

/// Helper-owned time limit survives parent UI cancellation or a stalled host.
/// A submitted stop is not proof of remote execution; find-stop observation is
/// kept separate, so the parent never invents a successful ring or stop.
struct NativeBudsToolsWatchdog {
    enum Kind: String { case find, fit }
    private(set) var kind: Kind?
    private var deadline: TimeInterval?
    private var stopIssued = false
    var cleanup: Data? {
        switch kind {
        case .find: return SamsungBudsSettingsPacket.frame(command: 0xA1, payload: [])
        case .fit: return SamsungBudsSettingsPacket.frame(command: 0x9D, payload: [0])
        case nil: return nil
        }
    }
    mutating func submitted(_ frame: SamsungBudsSettingsPacket.Frame, at now: TimeInterval) {
        guard now.isFinite else { return }
        if frame.command == 0xA6, frame.payload.isEmpty {
            kind = .find; deadline = now + NativeBudsToolsPacket.findDuration; stopIssued = false
        } else if frame.command == 0x9D, Array(frame.payload) == [1] {
            kind = .fit; deadline = now + 8; stopIssued = false
        } else if frame.command == 0xA1 || (frame.command == 0x9D && Array(frame.payload) == [0]) {
            stopIssued = true
        }
    }
    mutating func observed(_ frame: SamsungBudsSettingsPacket.Frame) {
        if kind == .find && NativeBudsToolsPacket.stopped(frame) { kind = nil; deadline = nil }
    }
    mutating func requestStop() -> Data? {
        guard !stopIssued else { return nil }
        stopIssued = true
        return cleanup
    }
    mutating func due(at now: TimeInterval) -> Data? {
        guard now.isFinite, let deadline, now >= deadline, !stopIssued else { return nil }
        stopIssued = true
        return cleanup
    }
}
