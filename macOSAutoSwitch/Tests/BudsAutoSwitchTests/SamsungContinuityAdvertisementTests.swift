import XCTest
import CryptoKit
@testable import BudsAutoSwitch

final class SamsungContinuityAdvertisementTests: XCTestCase {
    typealias A = SamsungContinuityAdvertisement
    let now: Int64 = 3_153_612_345
    // Independent Python hashlib/integer-bit reference, synthetic-reference.json.
    let short = "7500021841a1b005e4269ebc88654b1dd3bff7db"
    let extended = "750002187b4161e6884405fbebe3e5275eb8e9f46833c84213"
    let mixed = "750002187b0161e6884405fbebe3e521100b8af4fa050d442edcc6ae3c2f95a05991"
    let shortPlain = "021841a1b005e4269e008002001034c11234"
    let extendedPlain = "02187b4161e6884405fbebe3e55100fe02001034c11234"
    let mixedPlain = "02187b0161e6884405fbebe3e521100b6100820204140934c1123448deadbeef"
    func data(_ hex: String) -> Data {
        let chars = Array(hex); return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }
    func fingerprint() throws -> A.Fingerprint { try .init(provisionedBytes: Data(128...159)) }
    func decode(_ d: Data) throws -> A.Candidate {
        try A.decode(manufacturerData: d, fingerprint: fingerprint(), unixMilliseconds: now)
    }
    // Test-only mutation encoder. Golden inputs above do not call this helper.
    func wire(_ plain: Data) -> Data {
        var b = Array(plain)
        let ext = b[3] & 128 == 0
        let range = ext ? 5..<13 : 4..<9
        let start = ext ? (b[3] == 0x41 ? 13 : 16) : 9
        let seed = Int(b[range].reduce(0, ^))
        let table = Array(SHA256.hash(data: Data(128...159)))
        for i in start..<b.count { b[i] ^= table[(seed + i) % 32] }
        return Data([0x75, 0] + b)
    }
    func failure(_ d: Data, _ expected: A.Failure, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(d), file: file, line: line) { XCTAssertEqual($0 as? A.Failure, expected, file: file, line: line) }
    }
    func testIndependentShortGolden() throws {
        let c = try decode(data(short))
        XCTAssertEqual(c.format, .short); XCTAssertEqual(c.version, 4); XCTAssertEqual(c.device, .phone)
        XCTAssertEqual(c.capabilities.leCoCPSM, 0x80); XCTAssertEqual(c.capabilities.preferredTransport, .leCoC)
        XCTAssertTrue(c.capabilities.supportsRemoteRevision); XCTAssertFalse(c.isAuthenticated)
        XCTAssertEqual(c.deviceState, 2); XCTAssertEqual(c.flags, 16)
    }
    func testIndependentSixIterationExtendedGolden() throws {
        let c = try decode(data(extended))
        XCTAssertEqual(c.format, .extendedAccount); XCTAssertEqual(c.version, 6)
        XCTAssertEqual(c.capabilities.leCoCPSM, 0xfe); XCTAssertEqual(c.capabilities.preferredTransport, .leCoC)
        let f = try A.discoveryFilter(fingerprint: fingerprint(), extended: true, unixMilliseconds: now)
        XCTAssertEqual(Data(f.mask), data("2400800002080004"))
        let rotated = A.rotate(Array(128...159), by: 73)
        XCTAssertEqual(Data(A.bitMask(rotated, outputBytes: 8, iterations: 6)), data("2400800002080004"))
        XCTAssertNotEqual(A.bitMask(rotated, outputBytes: 8, iterations: 9), f.mask)
    }
    func testIndependentShortMaskAndReversedBitOrder() throws {
        let f = try A.discoveryFilter(fingerprint: fingerprint(), extended: false, unixMilliseconds: now)
        XCTAssertEqual(Data(f.mask), data("0802a80418"))
        XCTAssertEqual(Data(zip(f.mask, f.hash).map(^)), data("19365b3387"))
        XCTAssertEqual(A.rotate([0, 1, 2, 3], by: 5), [3, 0, 1, 2])
    }
    func testIndependentMixedGoldenAndDistinctSPPFlag() throws {
        let c = try decode(data(mixed))
        XCTAssertEqual(c.format, .extendedMixed); XCTAssertEqual(c.extensionByte, 9)
        XCTAssertEqual(c.networkState, 4); XCTAssertEqual(c.flags, 0x14)
        XCTAssertEqual(c.capabilities.preferredTransport, .spp); XCTAssertEqual(c.capabilities.leCoCPSM, 0x82)
        XCTAssertFalse(c.isAuthenticated)
        // Separate Buds type-3 SPP bit must not change peer transport selection.
        var plain = data(shortPlain); plain.append(contentsOf: [0x33, 0x12, 0x34, 0x40])
        XCTAssertEqual(try decode(wire(plain)).capabilities.preferredTransport, .leCoC)
    }
    func testManufacturerAndFormatRejections() throws {
        var b = data(short); b[0] = 0; failure(b, .wrongManufacturer)
        b = data(short); b[1] = 0x75; failure(b, .wrongManufacturer)
        b = data(short); b[2] = 3; failure(b, .unknownFormat)
        b = data(short); b[4] = 0x51; failure(b, .unsupportedVersion)
        b = data(short); b[4] = 0x4f; failure(b, .unsupportedDevice)
        b = data(short); b[5] = 0xc1; failure(b, .unknownFormat)
        b = data(extended); b[5] = 0x21; failure(b, .unknownFormat)
        failure(Data(repeating: 0, count: 1653), .oversized)
        failure(data(short).dropFirst(2), .wrongManufacturer)
    }
    func testFingerprintAndClockValidation() throws {
        for count in [0, 1, 4097] { XCTAssertThrowsError(try A.Fingerprint(provisionedBytes: Data(repeating: 1, count: count))) }
        for count in [2, 32, 4096] { XCTAssertNoThrow(try A.Fingerprint(provisionedBytes: Data(repeating: 1, count: count))) }
        for time: Int64 in [-1, .max] {
            XCTAssertThrowsError(try A.decode(manufacturerData: data(short), fingerprint: fingerprint(), unixMilliseconds: time))
        }
        let f = try A.Fingerprint(provisionedBytes: Data(repeating: 0, count: 32))
        XCTAssertThrowsError(try A.decode(manufacturerData: data(short), fingerprint: f, unixMilliseconds: now)) {
            XCTAssertEqual($0 as? A.Failure, .noAccountMatch)
        }
        let before = try A.discoveryFilter(fingerprint: fingerprint(), extended: true, unixMilliseconds: 21_599_999)
        let after = try A.discoveryFilter(fingerprint: fingerprint(), extended: true, unixMilliseconds: 21_600_000)
        XCTAssertNotEqual(before.mask, after.mask)
        let same = try A.discoveryFilter(fingerprint: fingerprint(), extended: true, unixMilliseconds: 21_600_001)
        XCTAssertEqual(after.mask, same.mask)
    }
    func testEveryTruncatedGoldenPrefixAndDataSlice() throws {
        for h in [short, extended, mixed] {
            let packet = data(h)
            for n in 0..<packet.count {
                do {
                    let c = try decode(Data(packet.prefix(n)))
                    // A complete short base can stand alone at 16 company+payload bytes.
                    if h == short { XCTAssertEqual(n, 16) }
                    else { XCTAssertEqual(h, mixed); XCTAssertGreaterThanOrEqual(n, 29) }
                    XCTAssertFalse(c.isAuthenticated)
                } catch { XCTAssertNotNil(error as? A.Failure) }
            }
        }
        let padded = Data([9, 9, 9]) + data(short)
        XCTAssertEqual(try decode(padded.dropFirst(3)), try decode(data(short)))
    }
    func testAllLTVLengthMasksBoundedAndUnknownTypesRejected() throws {
        let base = Data(data(shortPlain).prefix(14))
        for type: UInt8 in 0...15 {
            for length: UInt8 in 0...15 {
                var plain = base
                plain.append((length << 4) | type)
                plain.append(contentsOf: repeatElement(UInt8(0), count: Int(length)))
                do {
                    let candidate = try decode(wire(plain)); XCTAssertFalse(candidate.isAuthenticated)
                    XCTAssertGreaterThan(length, 0)
                    XCTAssertTrue([1, 2, 3, 4, 6, 7, 8].contains(type))
                } catch { XCTAssertNotNil(error as? A.Failure) }
                if length > 0 {
                    plain.removeLast()
                    failure(wire(plain), .malformedLTV)
                }
            }
        }
    }
    func testBaseDuplicateMissingAndExtensionCoherence() throws {
        var b = data(shortPlain); b[3] = 0x91; failure(wire(b), .unknownFormat)
        b = data(extendedPlain); b[13] = 0x54; failure(wire(b), .missingContext)
        b = data(extendedPlain); b.append(contentsOf: [0x51, 0, 0x80, 2, 0, 0]); failure(wire(b), .duplicateContext)
        b = data(shortPlain); b[12] = 4; failure(wire(b), .malformedLTV)
        b = data(mixedPlain); b[20] = 0; failure(wire(b), .malformedLTV)
    }
    func testPSMRangesEvenAllowedAndSPPUnavailableCoC() throws {
        for psm: UInt16 in [0, 1, 0x7f, 0x100, 0x1001, 0xffff] {
            var b = data(shortPlain); b[9] = UInt8(psm >> 8); b[10] = UInt8(psm & 255)
            failure(wire(b), .invalidPSM)
            b[13] = 4 // SPP context can carry a disabled CoC listener sentinel.
            let c = try decode(wire(b)); XCTAssertNil(c.capabilities.leCoCPSM)
            XCTAssertEqual(c.capabilities.preferredTransport, .spp)
        }
        for psm: UInt8 in [0x80, 0x81, 0x82, 0xfe, 0xff] {
            var b = data(shortPlain); b[10] = psm
            XCTAssertEqual(try decode(wire(b)).capabilities.leCoCPSM, UInt16(psm))
        }
    }
    func testMixedPointerCannotEscapeOrParseOtherAccountTail() throws {
        for (index, value): (Int, UInt8) in [(13, 0x11), (14, 0), (14, 15), (14, 17), (15, 0), (15, 127), (15, 128), (15, 255)] {
            var b = data(mixed); b[index + 2] = value
            failure(b, .malformedLTV)
        }
        var b = data(mixed); b[b.count - 1] = 0 // Unrelated family tail is outside personal range.
        XCTAssertEqual(try decode(b), try decode(data(mixed)))
        b = data(mixed); b[17] = 5 // personal range truncates base, despite bytes after range
        failure(b, .malformedLTV)
    }
    func testPackedClientDataCannotEscapeLTV() throws {
        let base = Data(data(shortPlain).prefix(14))
        for suffix: [UInt8] in [[0x16, 1], [0x26, 1, 5], [0x36, 1, 2, 0], [0x86, 1, 6, 0, 0, 0, 0, 0, 0]] {
            failure(wire(base + Data(suffix)), .malformedLTV)
        }
        let c = try decode(wire(base + Data([0x46, 1, 2, 0, 0])))
        XCTAssertFalse(c.isAuthenticated)
    }
    func testEachAccountMaskBitRejectsAndUnmaskedNoiseDoesNot() throws {
        for (h, ext, start) in [(short, false, 6), (extended, true, 7), (mixed, true, 7)] {
            let filter = try A.discoveryFilter(fingerprint: fingerprint(), extended: ext, unixMilliseconds: now)
            for i in filter.mask.indices {
                for bit: UInt8 in 0...7 where filter.mask[i] & (1 << bit) != 0 {
                    var b = data(h); b[start + i] ^= 1 << bit
                    failure(b, .noAccountMatch)
                }
            }
        }
        // Noise is applied before context XOR, so re-encode the coherent context.
        var b = data(shortPlain)
        b[4] ^= 0x01 // absent in scan mask's first byte 08
        XCTAssertFalse(try decode(wire(b)).isAuthenticated)
    }
    func testRecognizedDeviceKindsAndMalformedMixedPersonalBoundary() throws {
        for type: UInt8 in [1, 2, 3] {
            var b = data(short); b[4] = 0x40 | type
            XCTAssertEqual(try decode(b).device.rawValue, type)
        }
        var b = data(mixed); b[17] = 10 // personal range splits final sequence LTV
        failure(b, .malformedLTV)
        // Length claims extension outside its own LTV, despite following bytes.
        var plain = data(shortPlain); plain[3] = 0xb1
        failure(wire(plain), .malformedLTV)
    }
    func testUnknownLTVFailClosedBeforeCandidate() throws {
        let base = Data(data(shortPlain).prefix(14))
        for type: UInt8 in [0, 5, 9, 10, 11, 12, 13, 14, 15] {
            failure(wire(base + Data([0x10 | type, 0])), .unsupportedLTV)
        }
    }
    func testRedactedDescriptions() throws {
        XCTAssertEqual(String(reflecting: try fingerprint()), "SamsungContinuityFingerprint(redacted)")
        XCTAssertEqual(String(reflecting: try decode(data(short))), "SamsungContinuityCandidate(untrusted)")
    }
}
