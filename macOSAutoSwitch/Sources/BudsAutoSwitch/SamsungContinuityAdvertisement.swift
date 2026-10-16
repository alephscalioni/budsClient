import Foundation
import CryptoKit

/// MCFDS 4.6.12.16 A15/A16/A18. Discovery is a probabilistic account
/// prefilter, NEVER peer identity or authentication. No account/key lookup.
enum SamsungContinuityAdvertisement {
    enum Failure: String, Error, Codable {
        case invalidFingerprint, invalidClock, oversized, wrongManufacturer, unknownFormat
        case truncated, malformedLTV, missingContext, duplicateContext, noAccountMatch
        case unsupportedVersion, unsupportedDevice, unsupportedLTV, invalidPSM
    }
    struct Fingerprint: CustomStringConvertible, CustomDebugStringConvertible {
        fileprivate let bytes: [UInt8]
        /// Provisioned certificate userFingerprint, decoded by the host. Source
        /// only requires length >1; 4096 is a local resource bound, not wire size.
        init(provisionedBytes: Data) throws {
            guard (2...4096).contains(provisionedBytes.count) else { throw Failure.invalidFingerprint }
            bytes = Array(provisionedBytes)
        }
        var description: String { "SamsungContinuityFingerprint(redacted)" }
        var debugDescription: String { description }
    }
    enum Format: Equatable { case short, extendedAccount, extendedMixed }
    enum Device: UInt8 { case phone = 1, tablet = 2, watch = 3 }
    enum PreferredTransport: Equatable { case spp, leCoC }
    struct Capabilities: Equatable {
        let preferredTransport: PreferredTransport
        /// LE dynamic PSM: even values are valid. No classic odd-PSM rule.
        let leCoCPSM: UInt16?
        let supportsRemoteRevision: Bool
    }
    struct Candidate: Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        let format: Format
        let version: UInt8
        let device: Device
        let deviceState: UInt8
        let networkState: UInt8
        let flags: UInt8
        let extensionByte: UInt8?
        let capabilities: Capabilities
        /// A match never changes this. SamsungPeerSession must authenticate KU,
        /// a known roster member AND the host's expected phone claimed address.
        var isAuthenticated: Bool { false }
        var description: String { "SamsungContinuityCandidate(untrusted)" }
        var debugDescription: String { description }
    }

    /// Input is precisely CBAdvertisementDataManufacturerDataKey Data, including
    /// little-endian company bytes 75 00, then Android payload 02 18.
    static func decode(manufacturerData: Data, fingerprint: Fingerprint,
                       unixMilliseconds: Int64) throws -> Candidate {
        guard manufacturerData.count <= 1652 else { throw Failure.oversized }
        let input = Array(manufacturerData)
        guard input.count >= 2 else { throw Failure.truncated }
        guard input[0] == 0x75, input[1] == 0 else { throw Failure.wrongManufacturer }
        var b = Array(input.dropFirst(2))
        guard b.count >= 14 else { throw Failure.truncated }
        guard b[0] == 2, b[1] == 0x18 else { throw Failure.unknownFormat }
        let format: Format
        let range: Range<Int>
        let filterRange: Range<Int>
        let xorStart: Int
        let versionDevice: UInt8
        if b[3] & 0x80 != 0 {
            guard b[3] == 0xa1 || b[3] == 0xb1 else { throw Failure.unknownFormat }
            format = .short; range = 3..<b.count; filterRange = 4..<9
            xorStart = 9; versionDevice = b[2]
        } else {
            guard b.count >= 21 else { throw Failure.truncated } // pa.a.c
            filterRange = 5..<13; versionDevice = b[4]
            switch b[3] {
            case 0x41:
                format = .extendedAccount; range = 13..<b.count; xorStart = 13
            case 0x01:
                // A15 maker emits 21 10 <signed-positive personal length>.
                // Other layouts are not established by this artifact.
                guard b[13] == 0x21, b[14] == 16, b[15] > 0, b[15] < 128,
                      16 + Int(b[15]) <= b.count else { throw Failure.malformedLTV }
                format = .extendedMixed; range = 16..<(16 + Int(b[15])); xorStart = 16
            default: throw Failure.unknownFormat
            }
        }
        let version = versionDevice >> 4
        guard version == 4 || version == 6 else { throw Failure.unsupportedVersion }
        guard let device = Device(rawValue: versionDevice & 15) else { throw Failure.unsupportedDevice }
        let scan = try discoveryFilter(fingerprint: fingerprint, extended: format != .short,
                                       unixMilliseconds: unixMilliseconds)
        // Android ScanFilter: (received & mask) == (hash & mask).
        let received = Array(b[filterRange])
        guard zip(received.indices, received).allSatisfy({ i, byte in
            (byte & scan.mask[i]) == (scan.hash[i] & scan.mask[i])
        }) else { throw Failure.noAccountMatch }
        let table = Array(SHA256.hash(data: Data(fingerprint.bytes)))
        let seed = Int(b[filterRange].reduce(UInt8(0), ^)) % table.count
        for i in xorStart..<b.count { b[i] ^= table[(seed + i) % table.count] }
        var context: [UInt8]?
        var offset = range.lowerBound
        while offset < range.upperBound {
            let header = b[offset], length = Int(header >> 4), type = header & 15
            guard length > 0, length <= range.upperBound - offset - 1 else { throw Failure.malformedLTV }
            let value = Array(b[(offset + 1)..<(offset + 1 + length)])
            if type == 1 {
                guard context == nil else { throw Failure.duplicateContext }
                let expected = format == .short ? 10 : 5
                guard length == expected || length == expected + 1 else { throw Failure.malformedLTV }
                context = Array(value.dropFirst(format == .short ? 5 : 0))
            } else {
                switch type {
                case 2: guard (2...14).contains(length) else { throw Failure.malformedLTV }
                case 3: guard (3...5).contains(length) else { throw Failure.malformedLTV }
                case 4: break // source accepts >=1; sequence uses low six bits
                case 6:
                    var j = 0
                    while j < value.count {
                        let hasData = value[j] & 1 != 0; j += 1
                        if hasData {
                            guard j < value.count else { throw Failure.malformedLTV }
                            let n = Int(value[j]); j += 1
                            guard n <= 5, n <= value.count - j else { throw Failure.malformedLTV }
                            j += n
                        }
                    }
                case 7: guard length == 1 else { throw Failure.malformedLTV }
                case 8: guard length >= 4 else { throw Failure.malformedLTV }
                default: throw Failure.unsupportedLTV // local fail-closed policy; Android skips
                }
            }
            offset += 1 + length
        }
        guard let c = context else { throw Failure.missingContext }
        guard (c[3] & 4 != 0) == (c.count == 6) else { throw Failure.malformedLTV }
        let psm = UInt16(c[0]) << 8 | UInt16(c[1])
        let validPSM = (0x80...0xff).contains(psm)
        let spp = c[4] & 4 != 0
        guard spp || validPSM else { throw Failure.invalidPSM }
        return Candidate(format: format, version: version, device: device,
                         deviceState: c[2], networkState: c[3], flags: c[4],
                         extensionByte: c.count == 6 ? c[5] : nil,
                         capabilities: .init(preferredTransport: spp ? .spp : .leCoC,
                                             leCoCPSM: validPSM ? psm : nil,
                                             supportsRemoteRevision: c[4] & 16 != 0))
    }

    /// Exact n9.d scan clock; no invented skew windows or rotating parameters.
    static func discoveryFilter(fingerprint: Fingerprint, extended: Bool,
                                unixMilliseconds: Int64) throws -> (mask: [UInt8], hash: [UInt8]) {
        guard unixMilliseconds >= 0, unixMilliseconds <= Int64.max - 21_600_000 else { throw Failure.invalidClock }
        let rotation = Int((unixMilliseconds + 21_600_000) / 43_200_000)
        let mask = bitMask(rotate(fingerprint.bytes, by: rotation), outputBytes: extended ? 8 : 5,
                           iterations: extended ? 6 : 9)
        let filter = extended ? [0xc2, 0x09, 0xd4, 0x17, 0xf5, 0xa3, 0x6b, 0xe0] : shortXORFilter(fingerprint.bytes)
        return (mask, zip(mask, filter).map(^))
    }

    /// n9.b/l/n + n9.d/a: advertising uses BOTH current/next 12-hour
    /// rotations and nine injected random bit draws, unlike the scan filter.
    /// Narrow session encoder helper; fingerprint bytes never leave this type.
    static func encodeOwnedShortContext(_ plaintext: [UInt8], fingerprint: Fingerprint,
                                        unixMilliseconds: Int64, noiseBitPositions: [UInt8]) throws -> Data {
        guard unixMilliseconds >= 0, unixMilliseconds <= Int64.max - 21_600_000 else { throw Failure.invalidClock }
        guard plaintext.count >= 14, plaintext[0] == 2, plaintext[1] == 0x18,
              plaintext[3] == 0xa1 || plaintext[3] == 0xb1,
              noiseBitPositions.count == 9, noiseBitPositions.allSatisfy({ $0 < 40 }) else {
            throw Failure.unknownFormat
        }
        let rotation = Int(unixMilliseconds / 43_200_000)
        let current = bitMask(rotate(fingerprint.bytes, by: rotation), outputBytes: 5, iterations: 9)
        let next = bitMask(rotate(fingerprint.bytes, by: rotation + 1), outputBytes: 5, iterations: 9)
        var mask = zip(current, next).map(|)
        for bit in noiseBitPositions { setBit(&mask, Int(bit)) }
        let filter = zip(mask, shortXORFilter(fingerprint.bytes)).map(^)
        var result = plaintext
        result.replaceSubrange(4..<9, with: filter)
        let table = Array(SHA256.hash(data: Data(fingerprint.bytes)))
        let seed = Int(filter.reduce(UInt8(0), ^)) % table.count
        for i in 9..<result.count { result[i] ^= table[(seed + i) % table.count] }
        return Data(result)
    }
    static func rotate(_ bytes: [UInt8], by n: Int) -> [UInt8] {
        var out = bytes
        for i in bytes.indices { out[(i + n % bytes.count) % bytes.count] = bytes[i] }
        return out
    }
    static func bitMask(_ input: [UInt8], outputBytes: Int, iterations: Int) -> [UInt8] {
        var work = input, out = [UInt8](repeating: 0, count: outputBytes), sum = 0
        for _ in 0..<iterations {
            sum += SHA256.hash(data: Data(work)).reduce(0) { $0 + Int(Int8(bitPattern: $1)) }
            setBit(&out, abs(sum) % (8 * outputBytes)); work[0] &+= 1
        }
        return out
    }
    private static func setBit(_ bytes: inout [UInt8], _ n: Int) { bytes[bytes.count - 1 - n / 8] |= 1 << (n % 8) }
    private static func shortXORFilter(_ fingerprint: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 5), budget = 20
        for i in 0..<40 where Int(fingerprint[i % fingerprint.count]) % (40 - i) < budget {
            setBit(&result, i); budget -= 1
        }
        return result
    }
}
