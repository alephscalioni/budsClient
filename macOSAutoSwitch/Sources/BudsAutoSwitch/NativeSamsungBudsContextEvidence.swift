import Foundation

/// Observation of the system-owned local profiles, not an inference from an
/// A2DP stream, an ACL, or an app-created HandsFree object. No live source is
/// installed until it can establish these values for this selected session.
struct NativeSamsungBudsProfileObservation {
    let address: SamsungPeerAddress
    let session: UUID
    let observedAt: TimeInterval
    let hfp: SamsungContinuityBudsContext.HFP
    let bis: Bool
}

/// Session-scoped, expiring input for the Android type-3 Buds context. Unknown
/// metadata invalidates its older field; an omitted field does not refresh it.
struct NativeSamsungBudsContextEvidence {
    private struct Timed<Value> { let value: Value?; let at: TimeInterval; let notification: Bool }
    private(set) var session: UUID?
    private var address: SamsungPeerAddress?
    private var startedAt: TimeInterval = .infinity
    private var lastFrameAt: TimeInterval = -.infinity
    private var left: Timed<Bool>?
    private var right: Timed<Bool>?
    private var sppCount: Timed<Int>?
    /// Conservative publication budget, not a claimed Samsung wire timeout.
    static let maximumAge: TimeInterval = 5

    mutating func begin(address: SamsungPeerAddress, at now: TimeInterval) {
        self = Self()
        guard now.isFinite, now >= 0 else { return }
        self.address = address; session = UUID(); startedAt = now
    }
    mutating func reset() { self = Self() }

    mutating func observe(_ frame: SamsungMdePacket.Frame, session: UUID, at now: TimeInterval) {
        guard self.session == session, now.isFinite, now >= startedAt, now >= lastFrameAt,
              frame.command == 0x44 || frame.command == 0x45 else { return }
        lastFrameAt = now
        let notification = frame.command == 0x45
        guard let facts = SamsungMdeBudsObservation.decode(frame) else {
            Self.apply(.unknown, to: &left, at: now, notification: notification)
            Self.apply(.unknown, to: &right, at: now, notification: notification)
            Self.apply(.unknown, to: &sppCount, at: now, notification: notification)
            return
        }
        Self.apply(facts.wearingLeftObservation, to: &left, at: now, notification: notification)
        Self.apply(facts.wearingRightObservation, to: &right, at: now, notification: notification)
        Self.apply(facts.sppConnectionCountObservation, to: &sppCount, at: now, notification: notification)
    }
    private static func apply<Value: Equatable>(_ observation: SamsungMdeBudsObservation.Observation<Value>,
                                     to field: inout Timed<Value>?, at now: TimeInterval, notification: Bool) {
        // READ has no proven response correlation. It may seed a baseline but
        // cannot overwrite, refresh or resurrect a later NOTIFY for this field.
        guard notification || field?.notification != true else { return }
        switch observation {
        case .unreported: break
        case .unknown: field = Timed(value: nil, at: now, notification: notification)
        case .known(let value): field = Timed(value: value, at: now, notification: notification)
        }
    }
    private func fresh<Value>(_ field: Timed<Value>?, at now: TimeInterval) -> Value? {
        guard session != nil, now.isFinite, now >= startedAt, let field,
              now >= field.at, now - field.at <= Self.maximumAge else { return nil }
        return field.value
    }
    private func wearing(at now: TimeInterval) -> Bool? {
        let l = fresh(left, at: now), r = fresh(right, at: now)
        if l == true || r == true { return true }
        return l == false && r == false ? false : nil
    }
    func metadataReadiness(at now: TimeInterval) -> [String: Bool] {
        ["session_available": session != nil,
         "wearing_known": wearing(at: now) != nil,
         "spp_capacity_known": fresh(sppCount, at: now) != nil]
    }
    func context(profiles: NativeSamsungBudsProfileObservation?, foregroundA2DP: Bool,
                 at now: TimeInterval) -> SamsungContinuityBudsContext? {
        guard foregroundA2DP, let address, let session, let profiles,
              profiles.address == address, profiles.session == session,
              now.isFinite, profiles.observedAt.isFinite, profiles.observedAt >= startedAt,
              now >= profiles.observedAt, now - profiles.observedAt <= Self.maximumAge,
              let wearing = wearing(at: now), let count = fresh(sppCount, at: now) else { return nil }
        return SamsungContinuityBudsContext(address: address, hfp: profiles.hfp,
            a2dp: true, foreground: true, bis: profiles.bis,
            wearing: wearing, sppConnectable: count < 2)
    }
}
