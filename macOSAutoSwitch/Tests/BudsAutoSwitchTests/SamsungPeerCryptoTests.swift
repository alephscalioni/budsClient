import XCTest
import CryptoKit
@testable import BudsAutoSwitch

final class SamsungPeerCryptoTests: XCTestCase {
    private let crypto = SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification)

    func testAES256GCMIndependentKnownAnswerZeroNonceNoPrefixNoAAD() throws {
        // Standard AES-256 GCM zero-key/zero-IV 16-byte-zero test vector.
        let key = Data(repeating: 0, count: 32)
        let plain = Data(repeating: 0, count: 16)
        let expected = peerHex("cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919")
        XCTAssertEqual(try crypto.sealAccount(plain, accountKey: key), expected)
        XCTAssertEqual(try crypto.openAccount(expected, accountKey: key), plain)
        XCTAssertEqual(try crypto.sealAccount(Data(), accountKey: key), peerHex("530f8afbc74536b9a963b4f1c4cb738b"))
        var corrupt = expected; corrupt[31] ^= 1
        XCTAssertThrowsError(try crypto.openAccount(corrupt, accountKey: key))
        XCTAssertThrowsError(try crypto.openAccount(expected, accountKey: Data(repeating: 1, count: 32)))
        XCTAssertThrowsError(try crypto.openAccount(Data(expected.prefix(15)), accountKey: key))
        XCTAssertThrowsError(try crypto.sealAccount(plain, accountKey: Data(repeating: 0, count: 16)))
    }

    func testCBCIndependentOpenSSLFixtureIncludesPKCS7FullBlock() throws {
        // NIST AES-256 first block, plus full PKCS7 padding block independently
        // computed by /usr/bin/openssl enc -aes-256-cbc (synthetic public material).
        let key = peerHex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        let iv = peerHex("000102030405060708090a0b0c0d0e0f")
        let plain = peerHex("6bc1bee22e409f96e93d7e117393172a")
        let cipher = peerHex("f58c4c04d6e5f1ba779eabfb5f7bfbd6485a5c81519cf378fa36d42b8547edc0")
        let fixed = SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification, randomIV: { iv })
        XCTAssertEqual(try fixed.sealSession(plain, sessionKey: key), iv + cipher)
        XCTAssertEqual(try fixed.openSession(iv + cipher, sessionKey: key), plain)
        // Independently control final padding through preceding cipher block:
        // length0, length17 and a mismatching byte in a claimed16-byte pad.
        for (index, mask): (Int, UInt8) in [(31, 0x10), (31, 1), (30, 1)] {
            var badPadding = iv + cipher; badPadding[index] ^= mask
            XCTAssertThrowsError(try fixed.openSession(badPadding, sessionKey: key))
        }
        for count in [0, 15, 16, 17, 31, 33] {
            XCTAssertThrowsError(try fixed.openSession(Data(repeating: 0, count: count), sessionKey: key))
        }
        let invalidIV = SamsungPeerCrypto(curveBoundary: .p256CandidateRequiresVerification, randomIV: { Data(count: 12) })
        XCTAssertThrowsError(try invalidIV.sealSession(plain, sessionKey: key))
    }

    func testSyntheticCBCBoundariesAndFreshIV() throws {
        let key = Data(repeating: 0x67, count: 32)
        for count in [0, 1, 15, 16, 17, 31, 32, 1000] {
            let plain = Data((0..<count).map { UInt8($0 % 256) })
            let first = try crypto.sealSession(plain, sessionKey: key)
            let second = try crypto.sealSession(plain, sessionKey: key)
            XCTAssertEqual(first.count, 16 + ((count / 16) + 1) * 16)
            XCTAssertNotEqual(first.prefix(16), second.prefix(16))
            XCTAssertEqual(try crypto.openSession(first, sessionKey: key), plain)
        }
        XCTAssertThrowsError(try crypto.sealSession(Data(), sessionKey: Data(count: 31)))
        XCTAssertThrowsError(try crypto.sealSession(Data(count: 16_777_217), sessionKey: key))
    }

    func testRealP256SPKIRawECDHSyntheticRoundtripAndForeignCurveRejection() throws {
        let a = try crypto.makeEphemeralKey(); let b = try crypto.makeEphemeralKey()
        // Explicit prime256v1 OID 1.2.840.10045.3.1.7 in SubjectPublicKeyInfo.
        let prefix = peerHex("3059301306072a8648ce3d020106082a8648ce3d03010703420004")
        XCTAssertTrue(a.publicKeySPKI.starts(with: prefix)); XCTAssertEqual(a.publicKeySPKI.count, 91)
        let secret = try a.rawSharedSecret(remoteSPKI: b.publicKeySPKI)
        XCTAssertEqual(secret.count, 32)
        XCTAssertEqual(secret, try b.rawSharedSecret(remoteSPKI: a.publicKeySPKI))
        XCTAssertEqual(crypto.publicKeyHash(Data("abc".utf8)), peerHex("ba7816bf8f01"))
        XCTAssertThrowsError(try a.rawSharedSecret(remoteSPKI: Data([4, 1, 2])))
        XCTAssertThrowsError(try a.rawSharedSecret(remoteSPKI: P384.KeyAgreement.PrivateKey().publicKey.derRepresentation))
        XCTAssertEqual(crypto.compatibility, .p256CandidateRequiresVerification)
    }
}

/// Fixture utility only: literal byte strings are independent of production builders.
func peerHex(_ value: String) -> Data {
    precondition(value.count % 2 == 0)
    var output = Data(); var index = value.startIndex
    while index < value.endIndex {
        let end = value.index(index, offsetBy: 2)
        output.append(UInt8(value[index..<end], radix: 16)!); index = end
    }
    return output
}
