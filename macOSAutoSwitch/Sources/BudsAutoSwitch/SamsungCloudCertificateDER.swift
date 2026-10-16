import Foundation
import Security

/// DER/PKCS#10 for A05: keystore/l.java, X500Principal and SHA256WithRSA.
/// No Keychain access. Signatures are supplied by an owned Security key.
enum SamsungCloudCertificateDER {
    typealias Failure = SamsungCloudCertificate.Failure
    static func tagged(_ tag: UInt8, _ content: Data) -> Data {
        var length = content.count
        var bytes: [UInt8] = []
        repeat { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 } while length > 0
        return Data([tag] + (content.count < 128 ? [UInt8(content.count)] : [0x80 | UInt8(bytes.count)] + bytes)) + content
    }
    static func sequence(_ content: Data) -> Data { tagged(0x30, content) }
    static let rsaAlgorithm = Data([0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00])
    static let signatureAlgorithm = Data([0x30,0x0d,0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b,0x05,0x00])

    static func subject(_ deviceID: String) throws -> Data {
        try SamsungCloudCertificate.text(deviceID, maximum: 512)
        func rdn(_ oid: UInt8, _ value: String, tag: UInt8 = 0x13) -> Data {
            tagged(0x31, sequence(Data([0x06,0x03,0x55,0x04,oid]) + tagged(tag, Data(value.utf8))))
        }
        // X500Principal encodes the RFC2253 input in reverse RDN order.
        let printable = deviceID.unicodeScalars.allSatisfy {
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 '()+,-./:=?".unicodeScalars.contains($0)
        }
        return sequence(rdn(6, "KR") + rdn(11, "CSP") + rdn(10, "Samsung Electronics") + rdn(3, deviceID, tag: printable ? 0x13 : 0x0c))
    }

    static func requestInfo(deviceID: String, rsaPublicKey: Data) throws -> Data {
        // Security exports the PUBLIC RSA key as PKCS#1, not SPKI.
        var reader = Reader(rsaPublicKey)
        var key = Reader(try reader.read(0x30)); try reader.end()
        let modulus = try key.read(0x02), exponent = try key.read(0x02); try key.end()
        guard modulus.count == 257, modulus.first == 0, modulus[1] & 0x80 != 0,
              exponent == Data([1,0,1]) else { throw Failure.invalidCSR }
        return try sequence(Data([0x02,0x01,0x00]) + subject(deviceID) +
            sequence(rsaAlgorithm + tagged(0x03, Data([0]) + rsaPublicKey)) + Data([0xa0,0x00]))
    }

    static func csr(deviceID: String, privateKey: SecKey) throws -> Data {
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else { throw Failure.privateKeyUnavailable }
        let info = try requestInfo(deviceID: deviceID, rsaPublicKey: publicData)
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, info as CFData, nil) as Data?,
              signature.count == 256,
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, info as CFData, signature as CFData, nil) else {
            throw Failure.invalidCSR
        }
        return sequence(info + signatureAlgorithm + tagged(0x03, Data([0]) + signature))
    }

    @discardableResult
    static func validateCSR(_ data: Data, deviceID: String) throws -> Data {
        var root = Reader(data); var csr = Reader(try root.read(0x30)); try root.end()
        let info = try csr.read(0x30)
        guard sequence(try csr.read(0x30)) == signatureAlgorithm else { throw Failure.invalidCSR }
        let signature = try csr.read(0x03); try csr.end()
        var fields = Reader(info)
        guard try fields.read(0x02) == Data([0]), try sequence(fields.read(0x30)) == subject(deviceID) else { throw Failure.invalidCSR }
        var spki = Reader(try fields.read(0x30))
        guard sequence(try spki.read(0x30)) == rsaAlgorithm else { throw Failure.invalidCSR }
        let bits = try spki.read(0x03); try spki.end()
        guard try fields.read(0xa0).isEmpty, bits.first == 0, signature.first == 0, signature.count == 257 else { throw Failure.invalidCSR }
        try fields.end()
        let publicData = Data(bits.dropFirst())
        // Also enforces RSA2048 / exponent 65537 and canonical public-key DER.
        _ = try requestInfo(deviceID: deviceID, rsaPublicKey: publicData)
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
        guard let key = SecKeyCreateWithData(publicData as CFData, attributes, nil),
              SecKeyVerifySignature(key, .rsaSignatureMessagePKCS1v15SHA256, sequence(info) as CFData,
                                    Data(signature.dropFirst()) as CFData, nil) else { throw Failure.invalidCSR }
        return publicData
    }

    static func certificate(_ data: Data, now: Date, requireCurrentValidity: Bool = true) throws -> SecCertificate {
        guard data.count <= 65_536, let certificate = SecCertificateCreateWithData(nil, data as CFData) else { throw Failure.invalidCertificate }
        // Parse validity offline; SecTrustEvaluate would introduce an unnecessary
        // trust/network policy. This is syntax/expiry validation, not CA pinning.
        var root = Reader(data); var cert = Reader(try root.read(0x30)); try root.end()
        var tbs = Reader(try cert.read(0x30))
        if tbs.nextTag == 0xa0 { _ = try tbs.read(0xa0) }
        _ = try tbs.read(0x02); _ = try tbs.read(0x30); _ = try tbs.read(0x30)
        var validity = Reader(try tbs.read(0x30))
        func time(_ reader: inout Reader) throws -> Date {
            let tag = reader.nextTag
            guard tag == 0x17 || tag == 0x18 else { throw Failure.invalidCertificate }
            let raw = try reader.read(tag!)
            guard let value = String(data: raw, encoding: .ascii),
                  value.range(of: tag == 0x17 ? "^[0-9]{12}Z$" : "^[0-9]{14}Z$", options: .regularExpression) != nil else { throw Failure.invalidCertificate }
            let expanded: String
            if tag == 0x17 {
                expanded = (Int(value.prefix(2))! >= 50 ? "19" : "20") + value
            } else { expanded = value }
            let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0); format.calendar = Calendar(identifier: .gregorian)
            format.dateFormat = "yyyyMMddHHmmss'Z'"; format.isLenient = false
            guard let date = format.date(from: expanded), format.string(from: date) == expanded else { throw Failure.invalidCertificate }
            return date
        }
        let start = try time(&validity), end = try time(&validity); try validity.end()
        guard start < end else { throw Failure.invalidCertificate }
        if requireCurrentValidity && (start > now || end <= now) { throw Failure.expired }
        return certificate
    }

    struct Reader {
        private let bytes: [UInt8]
        private var index = 0
        init(_ data: Data) { bytes = Array(data) }
        var nextTag: UInt8? { index < bytes.count ? bytes[index] : nil }
        mutating func read(_ expected: UInt8) throws -> Data {
            guard bytes.count <= 131_072, index + 2 <= bytes.count, bytes[index] == expected else { throw Failure.malformed }
            index += 1
            let first = Int(bytes[index]); index += 1
            var length = first
            if first & 0x80 != 0 {
                let count = first & 0x7f
                guard count > 0, count <= 3, index + count <= bytes.count, bytes[index] != 0 else { throw Failure.malformed }
                length = 0
                for _ in 0..<count { length = (length << 8) | Int(bytes[index]); index += 1 }
                guard length >= 128 else { throw Failure.malformed }
            }
            guard length <= bytes.count - index else { throw Failure.malformed }
            defer { index += length }
            return Data(bytes[index..<(index + length)])
        }
        func end() throws { guard index == bytes.count else { throw Failure.malformed } }
    }
}
