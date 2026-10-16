import XCTest
@testable import BudsAutoSwitch

final class SamsungContinuityOwnedContextTests: XCTestCase {
    typealias C = SamsungContinuityOwnedContext
    typealias A = SamsungContinuityAdvertisement
    let draws: [UInt8] = Array(0...8)
    let now: Int64 = 3_153_612_345
    func hex(_ value: String) -> Data {
        let chars = Array(value)
        return Data(stride(from: 0, to: chars.count, by: 2).map {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)!
        })
    }
    func fingerprint() throws -> A.Fingerprint { try .init(provisionedBytes: Data(128...159)) }
    func builder(_ version: C.Version = .v4) throws -> C {
        C(fingerprint: try fingerprint(), version: version, role: .softwareTabletCompatibility)
    }
    func state(psm: UInt16 = 0, device: UInt8 = 0, network: UInt8 = 0,
               flags: UInt8 = 0, ext: UInt8? = nil, bt: UInt16 = 0) throws -> C.State {
        try .init(leCoCPSM: psm, deviceState: device, networkState: network,
                  flags: flags, extensionByte: ext, bluetoothState: bt)
    }
    // Known bytes produced independently in Python and checked against extracted
    // Android Java methods. See ../OwnedContextFixtures/verify.py and README.md.
    // Synthetic fingerprint only. Expected bytes never invoke Swift's decoder.
    func testIndependentSessionOnlyGolden() throws {
        var sequence = try C.Sequence(lastEmitted: 0)
        let packet = try builder().encode(state: state(), sequence: &sequence,
                                          unixMilliseconds: now, noiseBitPositions: draws)
        XCTAssertEqual(packet, hex("021842a1b105f536787ee5ef2fae49059282"))
        XCTAssertEqual(packet.count, 18)
        XCTAssertEqual(sequence.lastEmitted, 1)
        // Discovery's transport policy intentionally remains stricter; session
        // acceptance is established by Android r9.b.j/hc.b.h/r9.f.a, not decode.
        XCTAssertThrowsError(try A.decode(manufacturerData: Data([0x75, 0]) + packet,
                                         fingerprint: fingerprint(), unixMilliseconds: now)) {
            XCTAssertEqual($0 as? A.Failure, .invalidPSM)
        }
    }
    func testIndependentExtensionGoldenAndWrapGolden() throws {
        var sequence = try C.Sequence(lastEmitted: 61)
        let b = try builder(.v6)
        let s = try state(device: 10, network: 4, ext: 9, bt: 0x1234)
        let packet = try b.encode(state: s, sequence: &sequence,
                                  unixMilliseconds: 21_600_000, noiseBitPositions: draws)
        XCTAssertEqual(packet, hex("021862b11f7e7bf278e5ef25aa7d0da6bcca50"))
        XCTAssertEqual(sequence.lastEmitted, 62)
        let wrapped = try builder().encode(state: state(psm: 0x82, device: 22, network: 4,
                                                       flags: 0x14, ext: 9, bt: 0xbeef),
                                            sequence: &sequence, unixMilliseconds: 43_200_000,
                                            noiseBitPositions: draws)
        XCTAssertEqual(wrapped, hex("021842b11b5fcba078825a720c4702425ff804"))
        XCTAssertEqual(sequence.lastEmitted, 1)
        let candidate = try A.decode(manufacturerData: Data([0x75, 0]) + wrapped,
                                     fingerprint: fingerprint(), unixMilliseconds: 43_200_000)
        XCTAssertEqual(candidate.device, .tablet)
        XCTAssertEqual(candidate.deviceState, 22)
        XCTAssertEqual(candidate.capabilities.preferredTransport, .spp)
        XCTAssertEqual(candidate.capabilities.leCoCPSM, 0x82)
        XCTAssertEqual(candidate.flags, 0x14)
        XCTAssertEqual(candidate.extensionByte, 9)
        XCTAssertFalse(candidate.isAuthenticated)
    }
    func testIndependentNonExtensionStateBytes() throws {
        var sequence = try C.Sequence(lastEmitted: 1)
        let result = try builder().encode(state: state(device: 11, network: 0x12, bt: 0xabcd),
                                          sequence: &sequence, unixMilliseconds: 43_199_999,
                                          noiseBitPositions: draws)
        XCTAssertEqual(result, hex("021842a11f7e7bf278e5ef24bc7d30902915"))
    }
    func testSequencePersistsAcrossBuilderInstancesAndAllTransitions() throws {
        var sequence = try C.Sequence(lastEmitted: 0)
        var old: UInt8 = 0
        for index in 0..<186 {
            // New builder cannot reset the host-owned sequence.
            let packet = try builder().encode(state: state(), sequence: &sequence,
                                              unixMilliseconds: now, noiseBitPositions: draws)
            let value = sequence.lastEmitted
            XCTAssertEqual(value, UInt8(index % 62 + 1))
            // Exact r9.b.j rejection predicate, independent of Packet.revision.
            XCTAssertFalse(value == 0 || (value <= old && Int(old) - Int(value) < 31))
            // Independent known transform at the sequence offset in this fixture.
            XCTAssertEqual(packet[15] ^ 0x04, value)
            sequence = try C.Sequence(lastEmitted: value) // persistence roundtrip
            old = value
        }
        for invalid: UInt8 in [63, 64, 255] {
            XCTAssertThrowsError(try C.Sequence(lastEmitted: invalid))
        }
    }
    func testFailureDoesNotConsumeSequence() throws {
        var sequence = try C.Sequence(lastEmitted: 62)
        for noise in [[], Array(0...7), Array(0...9), [40] + Array(0...7)] as [[UInt8]] {
            XCTAssertThrowsError(try builder().encode(state: state(), sequence: &sequence,
                                                     unixMilliseconds: now, noiseBitPositions: noise)) {
                XCTAssertEqual($0 as? C.Failure, .invalidNoise)
            }
            XCTAssertEqual(sequence.lastEmitted, 62)
        }
        for time: Int64 in [-1, .max] {
            XCTAssertThrowsError(try builder().encode(state: state(), sequence: &sequence,
                                                     unixMilliseconds: time, noiseBitPositions: draws)) {
                XCTAssertEqual($0 as? A.Failure, .invalidClock)
            }
            XCTAssertEqual(sequence.lastEmitted, 62)
        }
    }
    func testStateRequiresCoherentExtensionAndRealPSMOrExplicitlyDisabled() throws {
        for psm: UInt16 in [1, 0x7f, 0x100, 0xffff] {
            XCTAssertThrowsError(try state(psm: psm))
        }
        for psm: UInt16 in [0, 0x80, 0x81, 0x82, 0xff] { XCTAssertNoThrow(try state(psm: psm)) }
        XCTAssertThrowsError(try state(network: 4))
        XCTAssertThrowsError(try state(ext: 0))
        XCTAssertNoThrow(try state(network: 4, ext: 0))
        // No inferred transport/support bits; caller may explicitly advertise
        // real SPP with CoC disabled, or neither on the existing session.
        XCTAssertEqual(try state().flags, 0)
        XCTAssertEqual(try state(flags: 4).flags, 4)
    }
    func testAdvertisingUsesTwoRotationsAndInjectedDrawsWithReplacement() throws {
        let b = try builder()
        for time: Int64 in [0, 21_599_999, 21_600_000, 43_199_999, 43_200_000, now] {
            var sequence = try C.Sequence(lastEmitted: 0)
            // Repeated draws are legal in n9.d.b, including bit 39.
            let packet = try b.encode(state: state(psm: 0x80), sequence: &sequence,
                                      unixMilliseconds: time, noiseBitPositions: Array(repeating: 39, count: 9))
            let f = try A.discoveryFilter(fingerprint: fingerprint(), extended: false,
                                          unixMilliseconds: time)
            for i in 0..<5 { XCTAssertEqual(packet[4 + i] & f.mask[i], f.hash[i] & f.mask[i]) }
            XCTAssertNoThrow(try A.decode(manufacturerData: Data([0x75, 0]) + packet,
                                          fingerprint: fingerprint(), unixMilliseconds: time))
        }
    }
    func testRedactedDescriptions() throws {
        let b = try builder()
        XCTAssertEqual(String(describing: b), "SamsungContinuityOwnedContext(redacted)")
        XCTAssertEqual(String(reflecting: b), "SamsungContinuityOwnedContext(redacted)")
        XCTAssertEqual(String(reflecting: try fingerprint()), "SamsungContinuityFingerprint(redacted)")
    }

    func buds() throws -> SamsungContinuityBudsContext {
        .init(address: try .init(bytes: hex("021324354657")), hfp: .absent,
              a2dp: true, foreground: true, bis: false, wearing: false, sppConnectable: false)
    }

    func testOptionalEmptyIsByteForByteCompatible() throws {
        for version: C.Version in [.v4, .v6] {
            for s in [try state(), try state(network: 4, ext: 9)] {
                for old: UInt8 in [0, 61, 62] {
                    var omitted = try C.Sequence(lastEmitted: old)
                    var empty = omitted
                    let a = try builder(version).encode(state: s, sequence: &omitted,
                                                        unixMilliseconds: now, noiseBitPositions: draws)
                    let b = try builder(version).encode(state: s, sequence: &empty,
                                                        unixMilliseconds: now, noiseBitPositions: draws, buds: nil)
                    XCTAssertEqual(a, b)
                    XCTAssertEqual(omitted, empty)
                    XCTAssertEqual(a.count, s.extensionByte == nil ? 18 : 19)
                }
            }
        }
    }

    func testIndependentBudsAccountFramingGoldens() throws {
        // Python SHA-256 reference, synthetic fingerprint 80..9f and addresses.
        // These full-wire constants cover type 3 before type 4, absolute XOR
        // offsets after insertion, extension layout, high-bit advID and wrap.
        var sequence = try C.Sequence(lastEmitted: 0)
        let plain = try builder().encode(state: state(), sequence: &sequence,
                                         unixMilliseconds: now, noiseBitPositions: draws, buds: buds())
        XCTAssertEqual(plain, hex("021842a1b105f536787ee5ef2fae4e15c58eec650853"))
        XCTAssertEqual(plain.count, 22)
        XCTAssertEqual(sequence.lastEmitted, 1)

        let high = SamsungContinuityBudsContext(address: try .init(bytes: hex("ff00800102a5")),
                                                hfp: .audioActive, a2dp: true, foreground: true,
                                                bis: true, wearing: true, sppConnectable: true)
        sequence = try C.Sequence(lastEmitted: 61)
        let extended = try builder(.v6).encode(state: state(device: 10, network: 4, ext: 9, bt: 0x1234),
                                               sequence: &sequence, unixMilliseconds: 21_600_000,
                                               noiseBitPositions: draws, buds: high)
        XCTAssertEqual(extended, hex("021862b11f7e7bf278e5ef25aa7d0da15b7d1a3c6d1942"))
        XCTAssertEqual(extended.count, 23)
        XCTAssertEqual(sequence.lastEmitted, 62)

        let connected = SamsungContinuityBudsContext(address: try .init(bytes: hex("123456789abc")),
                                                     hfp: .connected, a2dp: true, foreground: true,
                                                     bis: false, wearing: false, sppConnectable: false)
        let wrapped = try builder().encode(state: state(psm: 0x82, device: 22, network: 4,
                                                        flags: 0x14, ext: 9, bt: 0xbeef),
                                             sequence: &sequence, unixMilliseconds: 43_200_000,
                                             noiseBitPositions: draws, buds: connected)
        XCTAssertEqual(wrapped, hex("021842b11b5fcba078825a720c47024570fae6c079b9e6"))
        XCTAssertEqual(sequence.lastEmitted, 1)
    }

    func testBudsSequenceTransitionsAndSizeStayBounded() throws {
        var sequence = try C.Sequence(lastEmitted: 0)
        for i in 0..<186 {
            let wire = try builder().encode(state: state(), sequence: &sequence,
                                            unixMilliseconds: now, noiseBitPositions: draws, buds: buds())
            XCTAssertEqual(wire.count, 22)
            XCTAssertEqual(sequence.lastEmitted, UInt8(i % 62 + 1))
            // Fixed XOR byte at the shifted type-4 sequence offset.
            XCTAssertEqual(wire[19] ^ 0x64, sequence.lastEmitted)
            sequence = try C.Sequence(lastEmitted: sequence.lastEmitted)
        }
    }

    func testBudsFailureDoesNotConsumeSequence() throws {
        var sequence = try C.Sequence(lastEmitted: 62)
        let original = sequence
        for noise in [[], Array(0...7), Array(0...9), [40] + Array(0...7)] as [[UInt8]] {
            XCTAssertThrowsError(try builder().encode(state: state(), sequence: &sequence,
                                                     unixMilliseconds: now, noiseBitPositions: noise, buds: buds())) {
                XCTAssertEqual($0 as? C.Failure, .invalidNoise)
            }
            XCTAssertEqual(sequence, original)
        }
        for time: Int64 in [-1, .max] {
            XCTAssertThrowsError(try builder().encode(state: state(), sequence: &sequence,
                                                     unixMilliseconds: time, noiseBitPositions: draws, buds: buds())) {
                XCTAssertEqual($0 as? A.Failure, .invalidClock)
            }
            XCTAssertEqual(sequence, original)
        }
        let retry = try builder().encode(state: state(), sequence: &sequence,
                                         unixMilliseconds: now, noiseBitPositions: draws, buds: buds())
        XCTAssertEqual(retry, hex("021842a1b105f536787ee5ef2fae4e15c58eec650853"))
        XCTAssertEqual(sequence.lastEmitted, 1)
    }
}
