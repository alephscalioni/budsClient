import Foundation

extension SamsungBudsSettingsPacket {
    /// Ambient: original AMBIENT_VOLUME plus Samsung Buds3 Pro producer (0...4).
    /// ANC: Samsung Paran 8.5.26070351 i3.f.A sends raw 0...4 using 0x83;
    /// older original-client models retain their 0...1 high/low contract.
    enum Level: String, CaseIterable {
        case ambient, anc
        var command: UInt8 { self == .ambient ? 0x84 : 0x83 }
        static func forCommand(_ command: UInt8) -> Self? { allCases.first { $0.command == command } }
        func range(model: String) -> ClosedRange<Int>? {
            guard let profile = SamsungBudsModelProfile(rawValue: model) else { return nil }
            if self == .anc {
                if [.buds3Pro, .buds4, .buds4Pro].contains(profile) { return 0...4 }
                return [.budsPro, .budsFe, .budsCore, .buds3Fe].contains(profile) ? 0...1 : nil
            }
            switch profile {
            case .budsLive: return nil
            case .buds, .buds3Pro, .buds4, .buds4Pro: return 0...4
            case .budsPro: return 0...3
            default: return 0...2
            }
        }
        func offset(model: String) -> Int? {
            guard range(model: model) != nil else { return nil }
            if self == .anc { return 24 }
            return model == "Buds" || model == "BudsPlus" ? 9 : 23
        }
        static func observed(_ payload: [UInt8], model: String) -> [Self: Int] {
            Dictionary(uniqueKeysWithValues: allCases.compactMap { level in
                if ["Buds3", "Buds3Pro", "Buds3Fe", "BudsCore", "BudsFe"].contains(model),
                   payload.first.map({ !(1...4).contains($0) }) != false { return nil }
                guard let range = level.range(model: model), let offset = level.offset(model: model),
                      payload.indices.contains(offset), range.contains(Int(payload[offset])) else { return nil }
                // Samsung hides its ordinary ambient slider while custom
                // per-side amplification is enabled; do not silently undo it.
                if level == .ambient, model == "Buds3Pro", payload.count > 29, payload[29] != 0 { return nil }
                return (level, Int(payload[offset]))
            })
        }
        func accepts(_ value: Int, status: SamsungBudsSettingsPacket.Status) -> Bool {
            status.levels[self] != nil && range(model: status.model)?.contains(value) == true
        }
    }
}
