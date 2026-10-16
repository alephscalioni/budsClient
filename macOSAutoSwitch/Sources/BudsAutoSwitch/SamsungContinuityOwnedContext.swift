import Foundation

/// Pure MCFDS short context for Packet.advertisement on an existing owned
/// session (m9.e.q / r9.b.j). No company bytes, BLE AD envelope or Cloud ID.
/// This metadata is outside the command's inner CBC ciphertext; it is NOT an
/// independently authenticated advertisement or proof of account membership.
struct SamsungContinuityOwnedContext: CustomStringConvertible, CustomDebugStringConvertible {
    enum Failure: String, Error {
        case invalidSequence, invalidPSM, inconsistentExtension, invalidNoise
    }
    enum Version: UInt8 { case v4 = 4, v6 = 6 }
    /// Explicit software compatibility role only. hc.b.h maps this nibble to
    /// peer class 102; it never edits the registered Cloud device identity.
    enum Role: UInt8 { case softwareTabletCompatibility = 2 }

    /// qa.a.a cycles 1...62. Inject the last persisted value (0 only for first
    /// use); host serializes access and persists lastEmitted after each encode.
    /// A restart/reset without restoring it can be rejected by r9.b.j.
    struct Sequence: Equatable {
        private(set) var lastEmitted: UInt8
        init(lastEmitted: UInt8) throws {
            guard lastEmitted <= 62 else { throw Failure.invalidSequence }
            self.lastEmitted = lastEmitted
        }
        fileprivate mutating func advance() -> UInt8 {
            lastEmitted = lastEmitted == 62 ? 1 : lastEmitted + 1
            return lastEmitted
        }
    }

    /// Exact ea.b fields plus qa.a Bluetooth state, supplied from real local
    /// observations. No guessed idle/media/network values or capability defaults.
    /// flags bit 0x04 = incoming SPP; 0x10 = SCPM remote-revision API support.
    /// Neither bit may be set merely because an outgoing session exists.
    /// Android's two-byte Bluetooth value is address-derived (ga.k constructor /
    /// y5.b.a0: local address bytes 3 and 4), not a made-up connected-state bit.
    struct State: Equatable {
        let leCoCPSM: UInt16
        let deviceState: UInt8
        let networkState: UInt8
        let flags: UInt8
        let extensionByte: UInt8?
        let bluetoothState: UInt16

        init(leCoCPSM: UInt16, deviceState: UInt8, networkState: UInt8,
             flags: UInt8, extensionByte: UInt8?, bluetoothState: UInt16) throws {
            // Zero explicitly means no local incoming CoC listener. Unlike
            // discovery, session context acceptance has no transport gate:
            // r9.b.j -> pa.a.f/g -> hc.b.h -> r9.f.a (returns true).
            // Android's ng.f0.j0 uses -1 when absent; zero is also parseable,
            // but is our explicit disabled value, not its producer default.
            guard leCoCPSM == 0 || (0x80...0xff).contains(leCoCPSM) else { throw Failure.invalidPSM }
            guard (networkState & 4 != 0) == (extensionByte != nil) else { throw Failure.inconsistentExtension }
            self.leCoCPSM = leCoCPSM
            self.deviceState = deviceState
            self.networkState = networkState
            self.flags = flags
            self.extensionByte = extensionByte
            self.bluetoothState = bluetoothState
        }
    }

    private let fingerprint: SamsungContinuityAdvertisement.Fingerprint
    let version: Version
    let role: Role

    init(fingerprint: SamsungContinuityAdvertisement.Fingerprint, version: Version, role: Role) {
        self.fingerprint = fingerprint
        self.version = version
        self.role = role
    }

    /// n9.d.b performs nine draws in 0..<40, with replacement; inject them so
    /// the host owns entropy and this encoder stays deterministic and offline.
    /// Every call advances context sequence, independently of Packet.revision.
    /// A single optional Buds entry precedes type 4, as in Android's y5.b.O.
    /// cc.q.t0 rejects multiple Buds; nil preserves the original empty context.
    /// Failure leaves sequence untouched. Retransmit the returned bytes as-is;
    /// encode a fresh context for the next message. Host owns persistence.
    func encode(state: State, sequence: inout Sequence, unixMilliseconds: Int64,
                noiseBitPositions: [UInt8], buds: SamsungContinuityBudsContext? = nil) throws -> Data {
        guard noiseBitPositions.count == 9, noiseBitPositions.allSatisfy({ $0 < 40 }) else {
            throw Failure.invalidNoise
        }
        var next = sequence
        let value = next.advance()
        var bytes: [UInt8] = [2, 0x18, version.rawValue << 4 | role.rawValue,
                              state.extensionByte == nil ? 0xa1 : 0xb1]
        bytes += [0, 0, 0, 0, 0] // owned account filter filled by the helper
        bytes += [UInt8(state.leCoCPSM >> 8), UInt8(state.leCoCPSM & 255),
                  state.deviceState, state.networkState, state.flags]
        if let extensionByte = state.extensionByte { bytes.append(extensionByte) }
        if let buds { bytes += buds.encode() }
        bytes += [0x34, value, UInt8(state.bluetoothState >> 8), UInt8(state.bluetoothState & 255)]
        let result = try SamsungContinuityAdvertisement.encodeOwnedShortContext(
            bytes, fingerprint: fingerprint, unixMilliseconds: unixMilliseconds,
            noiseBitPositions: noiseBitPositions)
        sequence = next
        return result
    }

    var description: String { "SamsungContinuityOwnedContext(redacted)" }
    var debugDescription: String { description }
}
