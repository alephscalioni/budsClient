import Foundation

extension SamsungBudsModelProfile {
    /// LockTouchpadEncoder sends five flags plus two call flags only when
    /// the model/revision declares AdvancedTouchLockForCalls. Buds3 Pro keeps
    /// its separately captured ten-byte contract; no Buds4 tail is reused.
    func touchPayloadLength(revision: Int) -> Int? {
        switch self {
        case .buds, .budsPlus, .budsLive, .budsPro: return nil
        case .buds2: return revision >= 7 ? 7 : revision >= 4 ? 5 : nil
        case .buds2Pro: return revision >= 1 ? 7 : 5
        case .buds3Pro: return (1...4).contains(revision) ? 10 : nil
        case .buds4, .buds4Pro: return 10
        default: return (1...4).contains(revision) ? 7 : nil
        }
    }
    /// The original client uses A0 until RingWhileWearing is supported.
    func findStartCommand(revision: Int) -> UInt8 {
        if [.buds, .budsPlus, .budsLive, .budsPro].contains(self) { return 0xA0 }
        if self == .buds2 && revision < 9 { return 0xA0 }
        if self == .buds2Pro && revision < 4 { return 0xA0 }
        return 0xA6
    }
}
