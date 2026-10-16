import Foundation

/// Minimal MCFDS type-3 LTV (qa.b case 0 / pa.a.g case 3).
/// All profile and sensor observations must be supplied explicitly by the caller.
/// No extras, volume, state inference, I/O or account framing lives here.
struct SamsungContinuityBudsContext: CustomStringConvertible, CustomDebugStringConvertible {
    enum HFP: UInt8 {
        case absent = 0, connected = 1, audioActive = 2
    }

    let address: SamsungPeerAddress
    let hfp: HFP
    let a2dp: Bool
    let foreground: Bool
    let bis: Bool
    let wearing: Bool
    /// Capacity to accept SPP, not evidence of an existing SPP connection.
    let sppConnectable: Bool

    init(address: SamsungPeerAddress, hfp: HFP, a2dp: Bool, foreground: Bool,
         bis: Bool, wearing: Bool, sppConnectable: Bool) {
        self.address = address
        self.hfp = hfp
        self.a2dp = a2dp
        self.foreground = foreground
        self.bis = bis
        self.wearing = wearing
        self.sppConnectable = sppConnectable
    }

    func encode() -> Data {
        let advID = address.advertisingID
        let flags = hfp.rawValue
            | (a2dp ? 0x04 : 0) | (foreground ? 0x08 : 0)
            | (bis ? 0x10 : 0) | (wearing ? 0x20 : 0)
            | (sppConnectable ? 0x40 : 0)
        return Data([0x33, UInt8(advID >> 8), UInt8(advID & 0xff), flags])
    }

    var description: String { "SamsungContinuityBudsContext(redacted)" }
    var debugDescription: String { description }
}
