import Foundation

/// Completed facts only. Reads, pending/failed acquisitions and cancellation
/// are deliberately not banner events. `occurredAt` is monotonic, captured at proof.
struct NativeConnectionBannerEvent: Equatable {
    enum Kind: Equatable {
        case directMacConnection
        case acquiredFromOtherDevice
        case departedFromMac(destination: VerifiedDestination?)
    }

    /// Caller attestation: the peer's identity AND remote audio ownership must
    /// be correlated with this exact Buds transfer. A selected/authenticated
    /// roster peer, switch request or ACK alone does not satisfy this contract.
    struct VerifiedDestination: Equatable {
        let budsAddress: String
        let peerAddress: String
        let name: String
        let transferID: UUID

        init?(budsAddress: String, peerAddress: String, name: String, transferID: UUID) {
            guard let buds = NativeConnectionBannerPolicy.normalizedAddress(budsAddress),
                  let peer = NativeConnectionBannerPolicy.normalizedAddress(peerAddress), buds != peer else { return nil }
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            self.budsAddress = buds; self.peerAddress = peer; self.name = name; self.transferID = transferID
        }
    }

    let id: UUID
    let address: String
    let name: String
    let kind: Kind
    let occurredAt: TimeInterval

    init(id: UUID = UUID(), address: String, name: String, kind: Kind, occurredAt: TimeInterval) {
        self.id = id; self.address = address; self.name = name; self.kind = kind; self.occurredAt = occurredAt
    }

    /// Compatibility with the existing verified model callback. Never parse a
    /// phone name out of free text or promote the old generic Galaxy label.
    static func legacy(address: String, name: String, destination: String,
                       occurredAt: TimeInterval) -> Self? {
        let kind: Kind
        switch destination {
        case "Conectado ao Mac", "Connected to Mac": kind = .acquiredFromOtherDevice
        case "Conectado ao Galaxy", "Connected to Galaxy", "Conectado a outro dispositivo", "Connected to another device":
            kind = .departedFromMac(destination: nil)
        default: return nil
        }
        return .init(address: address, name: name, kind: kind, occurredAt: occurredAt)
    }
}

struct NativeConnectionBannerPresentation: Equatable {
    let event: NativeConnectionBannerEvent
    let destination: String
    let systemImage: String
}

/// One transition gate shared by every automatic HUD entry point. Time-based
/// debounce would repeat long-lived states and suppress quick real reconnects.
struct NativeConnectionBannerPolicy {
    private enum Target { case mac, other }
    private struct State {
        var target: Target?
        var lastEvidenceAt: TimeInterval = -.infinity
    }
    private var states: [String: State] = [:]

    /// Passive evidence rearms a subsequent Mac connection without displaying
    /// anything. A physical loss does not identify a remote destination.
    mutating func observeLink(address: String, connected: Bool, at time: TimeInterval) {
        guard let address = Self.normalizedAddress(address), time.isFinite, time >= 0 else { return }
        var state = states[address] ?? State()
        guard time >= state.lastEvidenceAt else { return }
        state.lastEvidenceAt = time
        if !connected, state.target == .mac { state.target = nil }
        states[address] = state
    }

    mutating func presentation(for event: NativeConnectionBannerEvent,
                               language: AppLanguage = .current)
        -> NativeConnectionBannerPresentation? {
        guard let address = Self.normalizedAddress(event.address), event.occurredAt.isFinite,
              event.occurredAt >= 0 else { return nil }
        var state = states[address] ?? State()
        guard event.occurredAt >= state.lastEvidenceAt else { return nil }
        state.lastEvidenceAt = event.occurredAt
        let target: Target
        let destination: String
        let symbol: String
        switch event.kind {
        case .directMacConnection:
            target = .mac; destination = LocalizedText.connectedToMac.string(language)
            symbol = "laptopcomputer"
        case .acquiredFromOtherDevice:
            target = .mac; destination = LocalizedText.connectedToMac.string(language)
            symbol = "arrow.down.left.circle"
        case .departedFromMac(let peer):
            target = .other; symbol = "arrow.up.right.circle"
            if let peer, peer.budsAddress == address, peer.transferID == event.id {
                destination = LocalizedText.disconnected(to: peer.name, language)
            } else {
                destination = LocalizedText.disconnected(to: LocalizedText.disconnectedToAnother.string(language), language)
            }
        }
        let repeated = state.target == target
        state.target = target; states[address] = state
        guard !repeated else { return nil }
        return .init(event: event, destination: destination, systemImage: symbol)
    }

    static func normalizedAddress(_ value: String) -> String? {
        let pattern = "^(?:[0-9a-fA-F]{12}|(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}|(?:[0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2})$"
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let compact = value.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        guard compact != "000000000000", compact != "FFFFFFFFFFFF" else { return nil }
        let bytes = Array(compact)
        return stride(from: 0, to: 12, by: 2).map { String(bytes[$0...($0 + 1)]) }.joined(separator: ":")
    }
}
