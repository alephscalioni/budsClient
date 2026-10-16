import Foundation

extension SamsungMdePacket {
    enum AccountTagEcho: String { case matching, zero, byteReversed = "byte_reversed", different }
    /// Diagnostic equality only: a two-byte MDE account tag is not authentication.
    /// Neither the tag nor the provisioned fingerprint leaves this helper.
    static func accountTagMatches(_ incoming: Frame, ownedConfiguration: Data) -> Bool? {
        accountTagEchoStatus(incoming, ownedConfiguration: ownedConfiguration).map { $0 == .matching }
    }
    static func accountTagEchoStatus(_ incoming: Frame, ownedConfiguration: Data) -> AccountTagEcho? {
        guard let configured = decodeCompleteFrame(ownedConfiguration), configured.command == 0x43 else { return nil }
        let config = Array(configured.payload)
        guard config.count == 10, Array(config.prefix(6)) == [4, 3, 7, 0, 0, 11], [2, 3].contains(config[6]), config[7] == 1,
              !incoming.isFragment, incoming.command == 0x44 || incoming.command == 0x45 else { return nil }
        let bytes = Array(incoming.payload)
        var i = incoming.command == 0x44 ? 2 : 0
        guard bytes.count >= i else { return nil }
        var match: AccountTagEcho?
        while i < bytes.count {
            guard bytes.count - i >= 3 else { return nil }
            let key = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            let count = Int(bytes[i + 2]), start = i + 3
            guard count <= bytes.count - start else { return nil }
            if key == 0x0502, count >= 8, bytes[start] == 0x0b {
                let first = bytes[start + 5], second = bytes[start + 6]
                if first == config[8] && second == config[9] { match = .matching }
                else if first == 0 && second == 0 { match = .zero }
                else if first == config[9] && second == config[8] { match = .byteReversed }
                else { match = .different }
            }
            i = start + count
        }
        return match
    }
}
