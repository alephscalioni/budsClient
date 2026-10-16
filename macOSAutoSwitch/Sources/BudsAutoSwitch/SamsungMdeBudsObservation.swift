import Foundation

/// Stateless facts from an already validated, complete SMEP Frame.
/// Retains only wearing and SPP availability evidence, never property payloads.
struct SamsungMdeBudsObservation: Equatable {
    /// A present but invalid value must be able to invalidate older evidence.
    enum Observation<Value: Equatable>: Equatable {
        case unreported
        case known(Value)
        case unknown

        var value: Value? {
            guard case let .known(value) = self else { return nil }
            return value
        }
    }

    let wearingLeftObservation: Observation<Bool>
    let wearingRightObservation: Observation<Bool>
    let sppConnectionCountObservation: Observation<Int>

    var wearingLeft: Bool? { wearingLeftObservation.value }
    var wearingRight: Bool? { wearingRightObservation.value }
    var sppConnectionCount: Int? { sppConnectionCountObservation.value }

    var wearing: Bool? {
        if wearingLeft == true || wearingRight == true { return true }
        if wearingLeft == false && wearingRight == false { return false }
        return nil
    }

    var sppConnectable: Bool? { sppConnectionCount.map { $0 < 2 } }

    /// SamsungMdePacket accepts at most 1027 wire bytes, with eight framing bytes.
    /// Each TLV consumes at least three bytes, bounding traversal to 339 TLVs.
    private static let maximumPayloadLength = 1027 - 8

    static func decode(_ frame: SamsungMdePacket.Frame) -> Self? {
        guard !frame.isFragment, frame.command == 0x44 || frame.command == 0x45,
              frame.payload.count <= maximumPayloadLength else { return nil }
        var index = frame.command == 0x44 ? 2 : 0
        guard frame.payload.count >= index else { return nil }
        let bytes = [UInt8](frame.payload)
        var left: Observation<Bool> = .unreported
        var right: Observation<Bool> = .unreported
        var spp: Observation<Int> = .unreported

        while index < bytes.count {
            guard bytes.count - index >= 3 else { return nil }
            let key = UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
            let length = Int(bytes[index + 2])
            let start = index + 3
            guard length <= bytes.count - start else { return nil }

            // Every relevant occurrence replaces the previous one, even when
            // its value is unknown. Unrelated properties are never retained.
            switch key {
            case 0x0206:
                left = length == 1 ? wearingValue(bytes[start]) : .unknown
            case 0x0207:
                right = length == 1 ? wearingValue(bytes[start]) : .unknown
            case 0x021F:
                // ga.d.f: ff leaves evidence unknown; only counts 0...2 are
                // demonstrated. Do not reproduce Java signed-byte comparisons.
                spp = length == 1 && bytes[start] <= 2 ? .known(Int(bytes[start])) : .unknown
            default:
                break
            }
            index = start + length
        }

        return Self(wearingLeftObservation: left, wearingRightObservation: right,
                    sppConnectionCountObservation: spp)
    }

    private static func wearingValue(_ value: UInt8) -> Observation<Bool> {
        // hb.k.h: 1 is wearing; 0 does not update evidence. Accept the explicit
        // non-wearing state 2, leaving sentinel/undocumented values unknown.
        switch value {
        case 1: return .known(true)
        case 2: return .known(false)
        default: return .unknown
        }
    }
}
