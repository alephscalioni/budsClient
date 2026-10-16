import Foundation

/// Owned Mac identity, with a software continuity role understood by MCFDS.
/// No Cloud row update, incoming listener, copied phone identity or OS IRK.
@MainActor enum NativeSamsungOwnedContextProvider {
    static let sequenceKey = "BudsContinuityOwnedContextSequence"

    static func make(material: SamsungCloudCertificate.PeerMaterial,
                     defaults: UserDefaults = .standard, now: Date = Date(),
                     buds: SamsungContinuityBudsContext? = nil) throws -> Data {
        guard let provisioned = material.accountFingerprint else {
            throw NativeSamsungPeerCoordinatorDiagnostics.Failure.invalidMaterial
        }
        let own = Array(try NativeSamsungPeerCoordinator.address(material.ownClassicAddress).bytes)
        let fingerprint = try SamsungContinuityAdvertisement.Fingerprint(provisionedBytes: provisioned.bytes)
        let encoder = SamsungContinuityOwnedContext(fingerprint: fingerprint, version: .v4,
            role: .softwareTabletCompatibility)
        // These are unreported/default device and network context, not an
        // assertion that the Mac display is off or a telephone call is idle.
        // No incoming CoC/SPP or Samsung SCPM revision service is advertised.
        // ga.k(String,..) / y5.b.a0 derive this two-byte identity from OWN BT
        // bytes 3 and 4. qa.a calls it bt; it is not a connection-state mask.
        let state = try SamsungContinuityOwnedContext.State(leCoCPSM: 0, deviceState: 0,
            networkState: 0, flags: 0, extensionByte: nil,
            bluetoothState: UInt16(own[3]) << 8 | UInt16(own[4]))
        let saved = defaults.object(forKey: sequenceKey)
        let last: UInt8
        if saved == nil { last = 0 }
        else if let number = saved as? NSNumber, number.intValue >= 0, number.intValue <= 62,
                number.doubleValue == Double(number.intValue) { last = UInt8(number.intValue) }
        else { throw SamsungContinuityOwnedContext.Failure.invalidSequence }
        var sequence = try SamsungContinuityOwnedContext.Sequence(lastEmitted: last)
        let milliseconds = now.timeIntervalSince1970 * 1000
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds < Double(Int64.max - 21_600_000) else {
            throw SamsungContinuityAdvertisement.Failure.invalidClock
        }
        let bytes = try encoder.encode(state: state, sequence: &sequence,
            unixMilliseconds: Int64(milliseconds), noiseBitPositions: (0..<9).map { _ in UInt8.random(in: 0..<40) }, buds: buds)
        // Reserve before submission: a failed send may have delivered bytes.
        // Skipping a value is accepted; reusing an acknowledged value is not.
        defaults.set(Int(sequence.lastEmitted), forKey: sequenceKey)
        return bytes
    }
}
