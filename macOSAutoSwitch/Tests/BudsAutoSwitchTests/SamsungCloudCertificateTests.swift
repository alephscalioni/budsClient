import XCTest
import Security
@testable import BudsAutoSwitch

/// All identities, certificates and tokens here are synthetic. RSA keys are
/// ephemeral imported SecKey objects. No test instantiates Keychain.
final class SamsungCloudCertificateTests: XCTestCase {
    typealias C = SamsungCloudCertificate
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let deviceID = "synthetic-mac-device"

    func key() throws -> SecKey {
        // macOS's RSA generator can contact securityd even for temporary keys.
        // Generate synthetic test material with local OpenSSL, then import it
        // into memory. No SecItem* / Keychain calls occur in the test process.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["genrsa", "2048"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); let pem = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let base64 = String(decoding: pem, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
        let der = try XCTUnwrap(Data(base64Encoded: base64))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate, kSecAttrKeySizeInBits as String: 2048]
        return try XCTUnwrap(SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil))
    }
    func publicData(_ key: SecKey) throws -> Data {
        try XCTUnwrap(SecKeyCopyExternalRepresentation(XCTUnwrap(SecKeyCopyPublicKey(key)), nil) as Data?)
    }
    func session(_ token: String = "synthetic-cloud-user") throws -> C.Session {
        try .init(deviceID: deviceID, accountID: "synthetic-user", cloudUserToken: token)
    }
    func identity() throws -> C.LocalIdentity {
        try .init(verifiedLocalBluetoothAddress: "12:34:56:78:9A:BC", controllerCoherentIRK: Data(repeating: 0x41, count: 16))
    }
    func device() throws -> C.Device {
        try .init(model: "SyntheticMac", name: "Offline Mac", type: "test-only", identity: identity())
    }
    func context() throws -> C.Context {
        let directory = try SamsungCloudProtocol.Directory.decode(Data(#"{"default":"https://api.samsungcloud.com","play":"https://play.samsungcloud.com"}"#.utf8))
        return C.Context(directory: directory, userAgent: "SyntheticSDK/1", network: "wifi", invoker: "synthetic-invoker")
    }
    // Small independent X.509 fixture builder; validity is fixed and the test
    // signs with its ephemeral RSA key. Security parses the resulting cert.
    func certificate(_ key: SecKey, expired: Bool = false) throws -> String {
        typealias D = SamsungCloudCertificateDER
        let name = try D.subject(deviceID)
        let validity = D.sequence(D.tagged(0x17, Data("260101000000Z".utf8)) +
            D.tagged(0x18, Data((expired ? "20270101000000Z" : "20360101000000Z").utf8)))
        let spki = D.sequence(D.rsaAlgorithm + D.tagged(0x03, Data([0]) + (try publicData(key))))
        let tbs = D.sequence(Data([0xa0,3,2,1,2,2,1,1]) + D.signatureAlgorithm + name + validity + name + spki)
        let signature = try XCTUnwrap(SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data?)
        return D.sequence(tbs + D.signatureAlgorithm + D.tagged(0x03, Data([0]) + signature)).base64EncodedString()
    }
    func object(_ key: SecKey) throws -> [String: Any] {
        let cert = try certificate(key)
        return ["userFingerprint": "0123456789aBcDeF", "userCertificate": cert, "serverCertificate": cert,
            "revision": 7,
            "userAesKeyList": [["aes128Key": Data(repeating: 0x42, count: 16).base64EncodedString(),
                "aes256Key": Data(repeating: 0x43, count: 32).base64EncodedString(), "expireTime": 1_900_000_000_000 as Int64]],
            "deviceInfoList": [["dvcId": deviceID, "deviceModel": "SyntheticMac", "deviceName": "Offline Mac", "deviceType": "test-only",
                "btAddr": "12:34:56:78:9A:BC", "irk": Data(repeating: 0x41, count: 16).base64EncodedString(),
                "certificate": cert, "createTime": 1_700_000_000_000 as Int64, "keyExpireTime": 1_900_000_000_000 as Int64]]]
    }
    func encode(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object) }
    func material(_ key: SecKey) throws -> Data { try encode(object(key)) }
    func assertFailure(_ code: C.Failure, _ work: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try work(), file: file, line: line) { XCTAssertEqual($0 as? C.Failure, code, file: file, line: line) }
    }

    func testDERLengthsAndCanonicalASN1() throws {
        typealias D = SamsungCloudCertificateDER
        XCTAssertEqual(D.tagged(4, Data(repeating: 1, count: 127)).prefix(2), Data([4,127]))
        XCTAssertEqual(D.tagged(4, Data(repeating: 1, count: 128)).prefix(3), Data([4,0x81,128]))
        XCTAssertEqual(D.tagged(4, Data(repeating: 1, count: 256)).prefix(4), Data([4,0x82,1,0]))
        for bytes: [UInt8] in [[4,0x80,0,0], [4,0x81,1,0], [4,0x82,0,128], [4,5,1], [4,0xff,0], [4]] {
            var reader = D.Reader(Data(bytes)); XCTAssertThrowsError(try reader.read(4))
        }
        var reader = D.Reader(Data([4,0,0])); _ = try reader.read(4); XCTAssertThrowsError(try reader.end())
        let subject = try D.subject("test")
        XCTAssertEqual(subject.map { String(format: "%02x", $0) }.joined(),
            "3048310b3009060355040613024b52310c300a060355040b1303435350311c301a060355040a131353616d73756e6720456c656374726f6e696373310d300b0603550403130474657374")
        XCTAssertThrowsError(try D.subject("bad\nCN=phone"))
    }

    func testCSRSignatureSPKISubjectAndTamperRejection() throws {
        let privateKey = try key()
        let csr = try SamsungCloudCertificateDER.csr(deviceID: deviceID, privateKey: privateKey)
        try SamsungCloudCertificateDER.validateCSR(csr, deviceID: deviceID)
        XCTAssertThrowsError(try SamsungCloudCertificateDER.validateCSR(csr, deviceID: "other-device"))
        var tampered = csr; tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try SamsungCloudCertificateDER.validateCSR(tampered, deviceID: deviceID))
        XCTAssertThrowsError(try SamsungCloudCertificateDER.validateCSR(csr + Data([0]), deviceID: deviceID))
        // Independent parser/signature verifier, local executable only.
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["req", "-inform", "DER", "-verify", "-noout", "-subject"]
        let input = Pipe(), output = Pipe(); process.standardInput = input; process.standardOutput = output; process.standardError = output
        try process.run(); input.fileHandleForWriting.write(csr); try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let text = String(decoding: result, as: UTF8.self)
        XCTAssertTrue(text.contains("verify OK") || text.contains("verify success"))
        for component in ["Samsung Electronics", "CSP", "KR", deviceID] { XCTAssertTrue(text.contains(component)) }
    }

    func testExactRequestSchemasCommonBearerAndNoLegacyHeaders() throws {
        let key = try key(), session = try session("Bearer synthetic-user-token"), context = try context()
        let csr = try SamsungCloudCertificateDER.csr(deviceID: deviceID, privateKey: key)
        let get = try context.request(session: session, method: "GET", revision: 7)
        XCTAssertEqual(get.url?.absoluteString, "https://api.samsungcloud.com/ca/v1/certificates?kcid=KC01&revision=7")
        XCTAssertNil(get.httpBody); XCTAssertNil(get.value(forHTTPHeaderField: "Content-Type"))
        let post = try context.request(session: session, method: "POST", device: device(), csr: csr)
        XCTAssertEqual(post.httpMethod, "POST"); XCTAssertEqual(post.url?.path, "/ca/v1/certificates")
        XCTAssertEqual(post.url?.query, "kcid=KC01")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["csr", "deviceInfo"])
        XCTAssertEqual(body["csr"] as? String, csr.base64EncodedString())
        XCTAssertEqual(body["deviceInfo"] as? [String: String], try device().body)
        let patch = try context.request(session: session, method: "PATCH", patch: .bluetoothAddress(identity()))
        XCTAssertEqual(patch.url?.absoluteString, "https://api.samsungcloud.com/ca/v1/device?kcid=KC01")
        let patched = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(patch.httpBody)) as? [String: String])
        XCTAssertEqual(Set(patched.keys), ["btAddress"]); XCTAssertNil(patched["btAddr"])
        let patchIRK = try context.request(session: session, method: "PATCH", patch: .irk(identity()))
        let irkBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(patchIRK.httpBody)) as? [String: String])
        XCTAssertEqual(irkBody, ["irk": Data(repeating: 0x41, count: 16).base64EncodedString()])
        for request in [get, post, patch] {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-user-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "SyntheticSDK/1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-sc-network"), "wifi")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-sc-agent-invoker"), "synthetic-invoker")
            for header in ["x-sc-app-id", "x-sc-access-token", "x-sc-uid", "x-sc-dvc-id", "x-sc-feature"] {
                XCTAssertNil(request.value(forHTTPHeaderField: header))
            }
        }
        XCTAssertEqual(C.feature, "certificate_v1")
        XCTAssertThrowsError(try context.request(session: session, method: "POST"))
        XCTAssertThrowsError(try context.request(session: session, method: "GET", revision: 0))
        XCTAssertThrowsError(try context.request(session: session, method: "DELETE"))
        XCTAssertThrowsError(try context.request(session: session, method: "POST", device: device(), csr: Data([1])))
        var injected = context; injected.invoker = "bad\r\nAuthorization: synthetic"
        XCTAssertThrowsError(try injected.request(session: session, method: "GET"))
    }

    func testStrictResponseSchemaExpiryFingerprintRosterAndRevision() throws {
        let key = try key(), original = try object(key)
        let decoded = try C.Material.decode(encode(original), now: now)
        try decoded.validateOwnedKey(publicData(key), deviceID: deviceID, now: now)
        XCTAssertTrue(decoded.containsThisDevice(deviceID, identity: try identity()))
        XCTAssertFalse(decoded.containsThisDevice(deviceID, identity: nil))
        XCTAssertFalse(decoded.containsThisDevice("other", identity: try identity()))
        XCTAssertThrowsError(try decoded.validateOwnedKey(publicData(self.key()), deviceID: deviceID, now: now))
        assertFailure(.existingCertificateWithoutOwnedKey) { try decoded.validateOwnedKey(nil, deviceID: deviceID, now: now) }
        assertFailure(.revisionRollback) { _ = try C.Material.decode(encode(original), now: now, minimumRevision: 8) }
        for field in ["revision", "userFingerprint", "userCertificate", "userAesKeyList", "deviceInfoList"] {
            var bad = original; bad.removeValue(forKey: field)
            XCTAssertThrowsError(try C.Material.decode(encode(bad), now: now), field)
        }
        for fingerprint in ["", "xyz", "abc", "12 34", "01\n"] {
            var bad = original; bad["userFingerprint"] = fingerprint
            XCTAssertThrowsError(try C.Material.decode(encode(bad), now: now))
        }
        for revision: Any in [-1, 1.5, true, "7", Int64(Int32.max) + 1] {
            var bad = original; bad["revision"] = revision
            XCTAssertThrowsError(try C.Material.decode(encode(bad), now: now))
        }
        for expiry: Int64 in [0, -1, 1_800_000_000, 1_800_000_000_000] {
            var bad = original, keys = bad["userAesKeyList"] as! [[String: Any]]
            keys[0]["expireTime"] = expiry; bad["userAesKeyList"] = keys
            XCTAssertThrowsError(try C.Material.decode(encode(bad), now: now))
        }
        var bad = original; bad["userCertificate"] = try certificate(key, expired: true)
        assertFailure(.expired) { _ = try C.Material.decode(encode(bad), now: now) }
        bad = original; bad["userCertificate"] = Data([0x30,0]).base64EncodedString()
        XCTAssertThrowsError(try C.Material.decode(encode(bad), now: now))
        bad = original; bad["deviceInfoList"] = Array(repeating: (original["deviceInfoList"] as! [[String: Any]])[0], count: 2)
        XCTAssertThrowsError(try C.Material.decode(encode(bad), now: now))
        for field in ["aes128Key", "aes256Key"] {
            bad = original; var keys = bad["userAesKeyList"] as! [[String: Any]]
            keys[0][field] = Data(repeating: 1, count: 15).base64EncodedString(); bad["userAesKeyList"] = keys
            XCTAssertThrowsError(try C.Material.decode(encode(bad), now: now))
        }
        bad = original; var peers = bad["deviceInfoList"] as! [[String: Any]]
        peers[0]["irk"] = Data(repeating: 1, count: 17).base64EncodedString(); bad["deviceInfoList"] = peers
        let unsupportedOwnIRK = try C.Material.decode(encode(bad), now: now)
        XCTAssertFalse(unsupportedOwnIRK.containsThisDevice(deviceID, identity: try identity()))
        peers[0]["irk"] = Data(repeating: 1, count: 8).base64EncodedString(); bad["deviceInfoList"] = peers
        let short = try C.Material.decode(encode(bad), now: now)
        XCTAssertFalse(short.containsThisDevice(deviceID, identity: try identity()))
        peers[0]["aes128Key"] = Data(repeating: 0x7b, count: 16).base64EncodedString()
        bad["deviceInfoList"] = peers
        let discarded = try C.Material.decode(encode(bad), now: now)
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: discarded.encodedForKeychain()) as? [String: Any])
        let persistedPeers = try XCTUnwrap(persisted["deviceInfoList"] as? [[String: Any]])
        XCTAssertNil(persistedPeers[0]["aes128Key"])
        peers[0]["aes128Key"] = "synthetic-invalid-key"; bad["deviceInfoList"] = peers
        XCTAssertThrowsError(try C.Material.decode(encode(bad), now: now))
        peers[0].removeValue(forKey: "aes128Key")
        peers[0]["keyExpireTime"] = 1_800_000_000_000 as Int64; bad["deviceInfoList"] = peers
        let expiredDevice = try C.Material.decode(encode(bad), now: now)
        assertFailure(.expired) { try expiredDevice.validateOwnedKey(publicData(key), deviceID: deviceID, now: now) }
        bad = original
        var roster = bad["deviceInfoList"] as! [[String: Any]]
        roster.append(["dvcId": "synthetic-retired-peer", "certificate": try certificate(key, expired: true)])
        bad["deviceInfoList"] = roster
        let historical = try C.Material.decode(encode(bad), now: now)
        try historical.validateOwnedKey(publicData(key), deviceID: deviceID, now: now)
    }

    func testAbsentPrerequisitesAndNoDiagnosticSecrets() throws {
        XCTAssertTrue(C.Diagnostics().publicValues.values.allSatisfy { !$0 })
        assertFailure(.missingAccount) { _ = try C.Session.account([:]) }
        let auth: [String: Any] = ["token_response": ["userId": "synthetic-user", "access_token": "synthetic-account-token"]]
        assertFailure(.missingCloudIdentity) { _ = try C.Session.account(auth) }
        var missing = auth; missing["cloud_registration"] = ["dvcId": deviceID]
        assertFailure(.missingCloudToken) { _ = try C.Session.account(missing) }
        XCTAssertTrue(SamsungCloudProtocol.certificateAccountDiagnostics(missing).cloudIdentityRegistered)
        XCTAssertFalse(SamsungCloudProtocol.certificateAccountDiagnostics(missing).certificateKeychainReady)
        missing["cloud_registration"] = ["dvcId": deviceID, "tokens": [["type": "user", "accessToken": "synthetic-user-token"]]]
        let state = SamsungCloudProtocol.certificateAccountDiagnostics(missing)
        XCTAssertTrue(state.accountAuthenticated); XCTAssertTrue(state.cloudIdentityRegistered)
        XCTAssertFalse(state.certificateKeychainReady); XCTAssertFalse(state.peerRosterContainsThisDevice)
        XCTAssertEqual(state.publicValues["peer_authenticated"], false)
        for token in ["", "Bearer ", "bad\nheader", "Bearer Bearer token", "Bearer\tvalue"] { XCTAssertThrowsError(try session(token)) }
        for address in ["", "UUID", "00:00:00:00:00:00", "02:00:00:00:00:00", "FF:FF:FF:FF:FF:FF"] {
            assertFailure(.missingBluetoothIdentity) { _ = try C.LocalIdentity(verifiedLocalBluetoothAddress: address, controllerCoherentIRK: Data(repeating: 1, count: 16)) }
        }
        for length in [0, 8, 15, 17] {
            assertFailure(.missingCoherentIRK) { _ = try C.LocalIdentity(verifiedLocalBluetoothAddress: "12:34:56:78:9A:BC", controllerCoherentIRK: Data(repeating: 1, count: length)) }
        }
        let material = try C.Material.decode(self.material(key()), now: now)
        let descriptions = [String(reflecting: try session()), String(reflecting: material),
            String(describing: try identity()), String(reflecting: material.deviceInfoList[0])]
        for description in descriptions {
            XCTAssertEqual(description, "[certificate material redacted]")
        }
        let diagnostics = String(decoding: try JSONSerialization.data(withJSONObject: state.publicValues), as: UTF8.self)
        for secret in [deviceID, "synthetic-user", "synthetic-cloud-user", "0123456789aBcDeF", "12:34:56:78:9A:BC", "Q0ND"] {
            XCTAssertFalse(diagnostics.contains(secret))
        }
        XCTAssertEqual(Mirror(reflecting: material).displayStyle, nil)
    }
    func testUnsupportedRemoteIRKIsExcludedWithoutInvalidatingOwnedCertificate() throws {
        let key = try key(); var document = try object(key)
        var peers = document["deviceInfoList"] as! [[String:Any]]
        var remote = peers[0]
        remote["dvcId"] = "synthetic-unsupported-remote"
        remote["btAddr"] = "22:34:56:78:9A:BC"
        remote["deviceType"] = "phone"
        remote["irk"] = Data(repeating:0x45,count:17).base64EncodedString()
        peers.append(remote); document["deviceInfoList"] = peers
        let identity = try C.LocalIdentity.outgoingClassicApplication(ownClassicAddress:"12:34:56:78:9A:BC",applicationIdentity:Data(repeating:0x41,count:16))
        let vault = try CertificateMemoryVault(key:key,data:encode(document))
        let material = try C.preparedPeerMaterial(session:session(),identity:identity,vault:vault,now:now)
        XCTAssertTrue(material.phones.isEmpty, "Unsupported remote IRK is never a connection candidate")
        peers[0]["irk"] = Data(repeating:0x45,count:17).base64EncodedString()
        document["deviceInfoList"] = peers
        vault.data = try encode(document)
        assertFailure(.peerRosterMismatch) { _ = try C.preparedPeerMaterial(session:session(),identity:identity,vault:vault,now:now) }
    }

    func testReRegisteredPhoneUsesNewerAddressIdentityAndQuarantinesConflictingTies() throws {
        let key = try key(); var document = try object(key)
        var peers = document["deviceInfoList"] as! [[String:Any]]
        var old = peers[0]
        old["dvcId"] = "synthetic-old"; old["btAddr"] = "22:34:56:78:9A:BC"
        old["deviceType"] = "phone"; old["deviceName"] = "Old registered phone"
        old["createTime"] = Int64(1_700_000_000_000)
        var recent = old; recent["dvcId"] = "synthetic-recent"; recent["deviceName"] = "Current registered phone"
        recent["irk"] = Data(repeating:0x46,count:16).base64EncodedString()
        recent["createTime"] = Int64(1_700_000_001_000)
        peers += [old,recent]; document["deviceInfoList"] = peers
        let identity = try C.LocalIdentity.outgoingClassicApplication(ownClassicAddress:"12:34:56:78:9A:BC",applicationIdentity:Data(repeating:0x41,count:16))
        let vault = try CertificateMemoryVault(key:key,data:encode(document))
        let material = try C.preparedPeerMaterial(session:session(),identity:identity,vault:vault,now:now)
        XCTAssertEqual(material.phones.count,1)
        XCTAssertEqual(material.phones.first?.name,"Current registered phone")
        peers[1]["createTime"] = peers[2]["createTime"]
        document["deviceInfoList"] = peers; vault.data = try encode(document)
        let ambiguous = try C.preparedPeerMaterial(session:session(),identity:identity,vault:vault,now:now)
        XCTAssertTrue(ambiguous.phones.isEmpty, "A conflicting equal-time identity cannot be selected arbitrarily")
    }

}
