import Foundation

/// Peer notification requires both the controller's actual Mac route ownership
/// and the exact observed MDE foreground/media stream (1). Pending 0x80 is insufficient.
struct NativeSamsungPeerCoordinatorOwnership {
    private(set) var epoch: UUID?
    mutating func update(enabled: Bool, ownsMac: Bool, status: SamsungMdePacket.MultipointStatus?) -> (acquired: UUID?, lost: Bool) {
        guard enabled && ownsMac else {
            let lost = epoch != nil; epoch = nil; return (nil, lost)
        }
        guard epoch == nil, status?.state == .foreground,
              status?.streamType.rawValue == 1 else { return (nil, false) }
        let next = UUID(); epoch = next; return (next, false)
    }
}
