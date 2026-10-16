import Foundation
import CryptoKit
import CommonCrypto
import Security

enum SamsungPeerCryptoFailure: String, Error {
    case invalidKey, invalidPublicKey, invalidIV, malformedCiphertext, encryption, decryption, randomGeneration
}

/// No identity lookup is possible through this interface. KU is an injected,
/// provisioned AES-256 capability, never a user ID, token, fingerprint or IRK.
protocol SamsungPeerCryptography {
    var compatibility: SamsungPeerDiagnostics.CryptoCompatibility { get }
    func makeEphemeralKey() throws -> SamsungPeerEphemeralKey
    func publicKeyHash(_ spki: Data) -> Data
    func sealAccount(_ plaintext: Data, accountKey: Data) throws -> Data
    func openAccount(_ ciphertext: Data, accountKey: Data) throws -> Data
    func sealSession(_ plaintext: Data, sessionKey: Data) throws -> Data
    func openSession(_ ciphertext: Data, sessionKey: Data) throws -> Data
}

protocol SamsungPeerEphemeralKey: AnyObject {
    var publicKeySPKI: Data { get }
    func rawSharedSecret(remoteSPKI: Data) throws -> Data
}

/// A07 proves EC.initialize(256), SPKI and raw ECDH, NOT a named curve.
/// This real CryptoKit implementation is a *P-256 compatibility candidate*.
/// Selecting it explicitly acknowledges the remaining Android-provider boundary;
/// synthetic roundtrips do not verify a Samsung peer. Inject another provider if
/// independent evidence establishes a different EC256 curve/encoding.
struct SamsungPeerCrypto: SamsungPeerCryptography {
    enum CurveBoundary { case p256CandidateRequiresVerification }
    let compatibility: SamsungPeerDiagnostics.CryptoCompatibility = .p256CandidateRequiresVerification
    private let randomIV: () throws -> Data

    init(curveBoundary: CurveBoundary, randomIV: @escaping () throws -> Data = SamsungPeerCrypto.secureIV) {
        self.randomIV = randomIV
    }

    private final class P256Key: SamsungPeerEphemeralKey, CustomDebugStringConvertible {
        private let key = P256.KeyAgreement.PrivateKey()
        var publicKeySPKI: Data { key.publicKey.derRepresentation }
        var debugDescription: String { "SamsungPeerEphemeralKey(redacted)" }
        func rawSharedSecret(remoteSPKI: Data) throws -> Data {
            do {
                let remote = try P256.KeyAgreement.PublicKey(derRepresentation: remoteSPKI)
                let secret = try key.sharedSecretFromKeyAgreement(with: remote)
                // Java KeyAgreement.generateSecret(), no HKDF or fingerprint KDF.
                return secret.withUnsafeBytes { Data($0) }
            } catch { throw SamsungPeerCryptoFailure.invalidPublicKey }
        }
    }
    func makeEphemeralKey() throws -> SamsungPeerEphemeralKey { P256Key() }
    func publicKeyHash(_ spki: Data) -> Data { Data(SHA256.hash(data: spki).prefix(6)) }

    /// A04/A07: fixed all-zero 12-byte IV, tag128, no AAD, no IV prefix.
    /// Nonce reuse is the recovered account protocol, not a general-purpose GCM
    /// construction. Never reuse these functions outside this compatibility scope.
    func sealAccount(_ plaintext: Data, accountKey: Data) throws -> Data {
        guard accountKey.count == 32 else { throw SamsungPeerCryptoFailure.invalidKey }
        guard plaintext.count <= 16_777_216 else { throw SamsungPeerWire.Failure.limit }
        do {
            let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: accountKey),
                                       nonce: AES.GCM.Nonce(data: Data(repeating: 0, count: 12)))
            // CryptoKit may return Data slices whose startIndex is not zero.
            // Produce an owned byte buffer at this API boundary.
            var output = Data(); output.append(box.ciphertext); output.append(box.tag)
            return output
        } catch { throw SamsungPeerCryptoFailure.encryption }
    }
    func openAccount(_ ciphertext: Data, accountKey: Data) throws -> Data {
        guard accountKey.count == 32 else { throw SamsungPeerCryptoFailure.invalidKey }
        guard ciphertext.count >= 16, ciphertext.count <= 16_777_232 else { throw SamsungPeerCryptoFailure.malformedCiphertext }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(repeating: 0, count: 12)),
                                             ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
            return try AES.GCM.open(box, using: SymmetricKey(data: accountKey))
        } catch { throw SamsungPeerCryptoFailure.decryption }
    }
    func sealSession(_ plaintext: Data, sessionKey: Data) throws -> Data {
        let iv = try randomIV()
        guard iv.count == 16 else { throw SamsungPeerCryptoFailure.invalidIV }
        var output = Data(); output.append(iv)
        output.append(try cbc(plaintext, key: sessionKey, iv: iv, encrypt: true)); return output
    }
    func openSession(_ ciphertext: Data, sessionKey: Data) throws -> Data {
        guard ciphertext.count >= 32, ciphertext.count <= 16_777_248,
              (ciphertext.count - 16) % 16 == 0 else { throw SamsungPeerCryptoFailure.malformedCiphertext }
        return try cbc(Data(ciphertext.dropFirst(16)), key: sessionKey, iv: Data(ciphertext.prefix(16)), encrypt: false)
    }
    private func cbc(_ input: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        guard [16, 24, 32].contains(key.count) else { throw SamsungPeerCryptoFailure.invalidKey }
        guard input.count <= (encrypt ? 16_777_216 : 16_777_232) else { throw SamsungPeerWire.Failure.limit }
        var output = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = output.count
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                input.withUnsafeBytes { inputBytes in
                    output.withUnsafeMutableBytes { out in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(encrypt ? kCCOptionPKCS7Padding : 0), keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress, inputBytes.baseAddress, input.count,
                                out.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw encrypt ? SamsungPeerCryptoFailure.encryption : SamsungPeerCryptoFailure.decryption
        }
        output.count = written
        if !encrypt {
            // Validate PKCS7 explicitly. Some CommonCrypto versions accept a
            // zero padding length; Java PKCS5Padding requires 1...16 equal bytes.
            guard let last = output.last, last > 0, last <= 16, Int(last) <= output.count else {
                throw SamsungPeerCryptoFailure.decryption
            }
            var different: UInt8 = 0
            for byte in output.suffix(Int(last)) { different |= byte ^ last }
            guard different == 0 else { throw SamsungPeerCryptoFailure.decryption }
            output.removeLast(Int(last))
        }
        return output
    }
    static func secureIV() throws -> Data {
        var iv = Data(count: 16)
        let result = iv.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        guard result == errSecSuccess else { throw SamsungPeerCryptoFailure.randomGeneration }
        return iv
    }
}
