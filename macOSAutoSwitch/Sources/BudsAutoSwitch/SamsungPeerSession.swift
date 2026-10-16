import Foundation

/// Safe to publish: closed vocabulary only, no account IDs, addresses, public-key
/// hashes, ciphertext, provider errors or private/session/account key material.
public struct SamsungPeerDiagnostics: Codable, Equatable {
    public enum Phase: String, Codable { case idle, awaitingInitiate, awaitingInitiateReply, awaitingReply, awaitingFinalSend, authenticated, failed, closed }
    public enum CryptoCompatibility: String, Codable { case p256CandidateRequiresVerification, injectedProviderRequiresVerification }
    public enum Failure: String, Error, Codable {
        case invalidConfiguration, missingRoster, localIdentityNotInRoster, unknownAddress, unexpectedAddress
        case unexpectedSequence, unsupportedAuthType, invalidEnvelope, malformedAuthentication
        case remoteRejected, invalidHash, invalidPublicKey, cryptoFailure, timeout, invalidClock
        case notAuthenticated, malformedSession, sequenceExhausted, closed
    }
    public let phase: Phase
    public let failure: Failure?
    public let cryptoCompatibility: CryptoCompatibility
    public let rosterAvailable: Bool
    public let peerRecognized: Bool
    public let sessionReady: Bool
}

/// An immutable enrollment snapshot supplied by the host. This file never queries
/// Cloud, keychain, accounts, hardware or IRKs. Address resolution, if needed,
/// must yield an enrolled canonical six-byte identity before this snapshot is built.
struct SamsungPeerRoster {
    let revision: Int32
    private let members: Set<SamsungPeerAddress>
    init(revision: Int32, members: Set<SamsungPeerAddress>) throws {
        guard !members.isEmpty, members.count <= 4096 else { throw SamsungPeerDiagnostics.Failure.missingRoster }
        self.revision = revision; self.members = members
    }
    func contains(_ address: SamsungPeerAddress) -> Bool { members.contains(address) }
}

/// Single-use, serialized by its owner (deliberately not Sendable). No transport
/// or timers run here. The host supplies monotonic seconds and calls pollTimeout
/// even when no packets arrive. Strict role/order, terminal failures, roster/local
/// identity checks and sequence exhaustion are local hardening, not claims of
/// recovered Android replay protection. Close and recreate after disconnect or
/// enrollment/roster changes. Dropping Data/key references is not guaranteed erasure.
final class SamsungPeerSession: CustomStringConvertible, CustomDebugStringConvertible {
    typealias Failure = SamsungPeerDiagnostics.Failure
    typealias Phase = SamsungPeerDiagnostics.Phase
    enum Role { case initiator, responder }
    struct ReceivedCommand {
        let handlerID: Int32
        let sequence: Int32
        let command: SamsungPeerWire.Command
        let advertisement: Data
        let revision: Int32?
    }

    private let role: Role
    private let localAddress: SamsungPeerAddress
    private let roster: SamsungPeerRoster
    private let expectedPeer: SamsungPeerAddress?
    private let crypto: SamsungPeerCryptography
    private let timeout: TimeInterval
    private let limits: SamsungPeerWire.Limits
    private var accountKey: Data?
    private var ephemeral: SamsungPeerEphemeralKey?
    private var sessionKey: Data?
    private var peer: SamsungPeerAddress?
    private var deadline: TimeInterval?
    private var lastTime: TimeInterval?
    private var nextSend: Int32?
    private var nextReceive: Int32?
    private var receivedFirst = false
    private(set) var phase: Phase = .idle
    private(set) var failure: Failure?

    /// KU must be provisioned account AES-256 bytes. No derivation is performed.
    /// Sequence initial values are transport-delegate policy: A09 establishes
    /// incrementing sends, not a universal initial counter. nil incoming accepts
    /// the first nonnegative sequence, then requires consecutive values.
    init(role: Role, accountKey: Data, localAddress: SamsungPeerAddress,
         roster: SamsungPeerRoster, expectedPeer: SamsungPeerAddress? = nil,
         crypto: SamsungPeerCryptography, timeout: TimeInterval = 10,
         initialSendSequence: Int32 = 1, initialReceiveSequence: Int32? = nil,
         limits: SamsungPeerWire.Limits = .standard) throws {
        guard accountKey.count == 32, timeout.isFinite, timeout > 0, timeout <= 300,
              initialSendSequence >= 0, initialReceiveSequence.map({ $0 >= 0 }) ?? true else { throw Failure.invalidConfiguration }
        guard roster.contains(localAddress) else { throw Failure.localIdentityNotInRoster }
        if let expectedPeer {
            guard expectedPeer != localAddress, roster.contains(expectedPeer) else { throw Failure.unknownAddress }
        }
        self.role = role; self.accountKey = accountKey; self.localAddress = localAddress
        self.roster = roster; self.expectedPeer = expectedPeer; self.crypto = crypto
        self.timeout = timeout; self.nextSend = initialSendSequence
        self.nextReceive = initialReceiveSequence; self.limits = limits
    }

    var diagnostics: SamsungPeerDiagnostics {
        .init(phase: phase, failure: failure, cryptoCompatibility: crypto.compatibility,
              rosterAvailable: true, peerRecognized: peer != nil,
              sessionReady: phase == .authenticated && sessionKey != nil)
    }
    var description: String { "SamsungPeerSession(\(phase.rawValue), \(failure?.rawValue ?? "none"))" }
    var debugDescription: String { description }

    /// Responder returns nil and waits. Timeout is one total handshake budget,
    /// not extended by malformed traffic or each intermediate message.
    func start(now: TimeInterval) throws -> SamsungPeerWire.Packet? {
        try ensureActive()
        guard phase == .idle else { throw terminate(.unexpectedSequence) }
        try checkClock(now)
        let expiry = now + timeout
        guard expiry.isFinite else { throw terminate(.invalidClock) }
        deadline = expiry
        if role == .responder { phase = .awaitingInitiate; return nil }
        do {
            let key = try crypto.makeEphemeralKey(); ephemeral = key
            var auth = SamsungPeerWire.Authentication(command: 1)
            auth.address = localAddress.bytes; auth.nonce = key.publicKeySPKI; auth.revision = roster.revision
            guard !auth.nonce.isEmpty else { throw Failure.invalidPublicKey }
            let packet = try authPacket(auth)
            phase = .awaitingInitiateReply; return packet
        } catch { throw terminate(mapped(error)) }
    }

    /// Returns a packet to send, if this step has a reply. Command 3 has no
    /// address/nonce: the responder uses its retained roster-resolved identity.
    func receiveAuthentication(_ packet: SamsungPeerWire.Packet, now: TimeInterval) throws -> SamsungPeerWire.Packet? {
        try ensureActive(); try checkClock(now); try checkTimeout(now)
        guard [.awaitingInitiate, .awaitingInitiateReply, .awaitingReply].contains(phase) else { throw terminate(.unexpectedSequence) }
        guard packet.handlerID == 0, packet.iv == nil else { throw terminate(.invalidEnvelope) }
        guard packet.authType == nil || packet.authType == 1 else { throw terminate(.unsupportedAuthType) }
        guard !packet.payload.isEmpty, packet.payload.count <= limits.messageBytes,
              let accountKey else { throw terminate(.invalidEnvelope) }
        do {
            let plaintext: Data
            do { plaintext = try crypto.openAccount(packet.payload, accountKey: accountKey) }
            catch { throw Failure.cryptoFailure }
            let auth: SamsungPeerWire.Authentication
            do { auth = try .decode(plaintext, limits: limits) }
            catch { throw Failure.malformedAuthentication }
            if auth.result == -1 { throw Failure.remoteRejected }
            let expected: Int32 = phase == .awaitingInitiate ? 1 : phase == .awaitingInitiateReply ? 2 : 3
            guard auth.command == expected else { throw Failure.unexpectedSequence }
            switch phase {
            case .awaitingInitiate:
                let recognized = try recognize(auth.address)
                let key = try crypto.makeEphemeralKey(); ephemeral = key
                sessionKey = try derive(key, auth.nonce)
                peer = recognized
                var reply = SamsungPeerWire.Authentication(command: 2)
                reply.address = localAddress.bytes; reply.nonce = key.publicKeySPKI
                reply.hash = crypto.publicKeyHash(auth.nonce); reply.revision = roster.revision
                guard !reply.nonce.isEmpty, reply.hash.count == 6 else { throw Failure.invalidPublicKey }
                let packet = try authPacket(reply); phase = .awaitingReply; return packet
            case .awaitingInitiateReply:
                guard let ephemeral else { throw Failure.unexpectedSequence }
                try verify(auth.hash, key: ephemeral)
                let recognized = try recognize(auth.address)
                sessionKey = try derive(ephemeral, auth.nonce); peer = recognized
                var reply = SamsungPeerWire.Authentication(command: 3)
                reply.hash = crypto.publicKeyHash(auth.nonce)
                guard reply.hash.count == 6 else { throw Failure.invalidPublicKey }
                let packet = try authPacket(reply)
                phase = .awaitingFinalSend; return packet
            case .awaitingReply:
                guard let ephemeral, let peer, roster.contains(peer), sessionKey != nil else { throw Failure.unexpectedSequence }
                // Strict local policy: command3 may omit address; if supplied it
                // must still identify the previously recognized enrolled peer.
                if !auth.address.isEmpty, auth.address != peer.bytes { throw Failure.unexpectedAddress }
                try verify(auth.hash, key: ephemeral)
                complete(); return nil
            default: throw Failure.unexpectedSequence
            }
        } catch { throw terminate(mapped(error)) }
    }

    /// Host calls only after the final reply has actually been written. This is
    /// stricter than Android's mark-complete-before-send branch. On write failure
    /// close() instead; producing a packet does not prove transport delivery.
    func confirmFinalReplySent(now: TimeInterval) throws {
        try ensureActive(); try checkClock(now); try checkTimeout(now)
        guard phase == .awaitingFinalSend, sessionKey != nil else { throw terminate(.unexpectedSequence) }
        complete()
    }

    func pollTimeout(now: TimeInterval) throws {
        try ensureActive(); try checkClock(now); try checkTimeout(now)
    }
    func close() {
        clearSecrets(); peer = nil; phase = .closed; failure = nil
    }

    /// CBC is not authenticated: successful padding/protobuf parsing never proves
    /// command integrity. Sequence checks below are local policy, not a MAC.
    func encodeCommand(_ command: SamsungPeerWire.Command, handlerID: Int32,
                       advertisement: Data = Data(), revision: Int32? = nil) throws -> SamsungPeerWire.Packet {
        try ensureAuthenticated()
        guard handlerID > 0 else { throw terminate(.invalidEnvelope) }
        guard let sequence = nextSend, let sessionKey else { throw terminate(.sequenceExhausted) }
        do {
            let payload = try crypto.sealSession(command.encoded(limits: limits), sessionKey: sessionKey)
            let packet = SamsungPeerWire.Packet(handlerID: handlerID, sequence: sequence, payload: payload,
                                                advertisement: advertisement, revision: revision)
            _ = try packet.encoded(limits: limits)
            nextSend = sequence == Int32.max ? nil : sequence + 1
            return packet
        } catch { throw terminate(.malformedSession) }
    }
    func receiveCommand(_ packet: SamsungPeerWire.Packet) throws -> ReceivedCommand {
        try ensureAuthenticated()
        guard packet.handlerID > 0, packet.authType == nil, packet.iv == nil,
              packet.sequence >= 0, packet.payload.count <= limits.messageBytes else { throw terminate(.invalidEnvelope) }
        if receivedFirst || nextReceive != nil {
            guard let expected = nextReceive, packet.sequence == expected else { throw terminate(.unexpectedSequence) }
        }
        guard let sessionKey else { throw terminate(.notAuthenticated) }
        do {
            _ = try packet.encoded(limits: limits)
            let plain = try crypto.openSession(packet.payload, sessionKey: sessionKey)
            let command = try SamsungPeerWire.Command.decode(plain, limits: limits)
            receivedFirst = true
            nextReceive = packet.sequence == Int32.max ? nil : packet.sequence + 1
            return .init(handlerID: packet.handlerID, sequence: packet.sequence, command: command,
                         advertisement: packet.advertisement, revision: packet.revision)
        } catch { throw terminate(.malformedSession) }
    }

    private func recognize(_ bytes: Data) throws -> SamsungPeerAddress {
        guard bytes.count == 6, let address = try? SamsungPeerAddress(bytes: bytes),
              address != localAddress, roster.contains(address) else { throw Failure.unknownAddress }
        guard expectedPeer == nil || expectedPeer == address else { throw Failure.unexpectedAddress }
        return address
    }
    private func derive(_ key: SamsungPeerEphemeralKey, _ remote: Data) throws -> Data {
        guard !remote.isEmpty else { throw Failure.invalidPublicKey }
        do {
            let secret = try key.rawSharedSecret(remoteSPKI: remote)
            guard [16, 24, 32].contains(secret.count) else { throw Failure.invalidPublicKey }
            return secret
        } catch { throw Failure.invalidPublicKey }
    }
    private func verify(_ hash: Data, key: SamsungPeerEphemeralKey) throws {
        let expected = crypto.publicKeyHash(key.publicKeySPKI)
        guard hash.count == 6, expected.count == 6 else { throw Failure.invalidHash }
        var different: UInt8 = 0
        for (a, b) in zip(hash, expected) { different |= a ^ b }
        guard different == 0 else { throw Failure.invalidHash }
    }
    private func authPacket(_ auth: SamsungPeerWire.Authentication) throws -> SamsungPeerWire.Packet {
        guard let accountKey else { throw Failure.unexpectedSequence }
        let payload = try crypto.sealAccount(auth.encoded(limits: limits), accountKey: accountKey)
        let packet = SamsungPeerWire.Packet(payload: payload, authType: 1)
        _ = try packet.encoded(limits: limits); return packet
    }
    private func complete() {
        phase = .authenticated; deadline = nil; ephemeral = nil; accountKey = nil
    }
    private func clearSecrets() { accountKey = nil; ephemeral = nil; sessionKey = nil; deadline = nil }
    private func terminate(_ reason: Failure) -> Failure {
        clearSecrets(); peer = nil; phase = .failed; failure = reason; return reason
    }
    private func ensureActive() throws {
        if phase == .closed { throw Failure.closed }
        if phase == .failed { throw failure ?? Failure.closed }
    }
    private func ensureAuthenticated() throws {
        try ensureActive()
        guard phase == .authenticated else { throw Failure.notAuthenticated }
    }
    private func checkClock(_ now: TimeInterval) throws {
        guard now.isFinite, lastTime.map({ now >= $0 }) ?? true else { throw terminate(.invalidClock) }
        lastTime = now
    }
    private func checkTimeout(_ now: TimeInterval) throws {
        if let deadline, now >= deadline { throw terminate(.timeout) }
    }
    private func mapped(_ error: Error) -> Failure { (error as? Failure) ?? .cryptoFailure }
}
