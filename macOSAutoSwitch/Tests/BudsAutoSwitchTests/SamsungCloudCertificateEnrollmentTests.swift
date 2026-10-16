import XCTest
import Security
@testable import BudsAutoSwitch

final class CertificateMemoryVault: SamsungCloudCertificateVault {
    var key: SecKey?
    var data: Data?
    var csrCalls = 0
    var saveCalls = 0
    var failSave = false
    var corruptSave = false
    init(key: SecKey? = nil, data: Data? = nil) { self.key = key; self.data = data }
    func publicKey() throws -> Data? {
        guard let key, let publicKey = SecKeyCopyPublicKey(key) else { return nil }
        return SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
    }
    func createCSR(deviceID: String) throws -> Data {
        csrCalls += 1
        guard let key else { throw SamsungCloudCertificate.Failure.privateKeyUnavailable }
        return try SamsungCloudCertificateDER.csr(deviceID: deviceID, privateKey: key)
    }
    func readMaterial() throws -> Data? { data }
    func saveMaterial(_ data: Data) throws {
        saveCalls += 1
        if failSave { throw SamsungCloudCertificate.Failure.keychainUnavailable }
        self.data = corruptSave ? Data([0]) : data
    }
}

extension SamsungCloudCertificateTests {
    @MainActor
    func testEnrollmentGetFirstOptInAndOwnedKeyPersistence() async throws {
        let key = try key(), response = try material(key), vault = CertificateMemoryVault(key: key)
        var methods: [String] = []
        let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { request in
            methods.append(request.httpMethod!)
            if request.httpMethod == "GET" { return (Data(), 204) }
            XCTAssertEqual(request.httpMethod, "POST")
            return (response, 201)
        }
        let result = await service.prepare(.enroll(try device()), now: now)
        XCTAssertNil(result.blocker)
        XCTAssertEqual(methods, ["GET", "POST"]); XCTAssertEqual(vault.csrCalls, 1); XCTAssertEqual(vault.saveCalls, 1)
        XCTAssertNotNil(vault.data)
        XCTAssertTrue(result.diagnostics.certificateKeychainReady)
        XCTAssertTrue(result.diagnostics.peerRosterContainsThisDevice)
        XCTAssertEqual(result.diagnostics.publicValues["peer_authenticated"], false)
    }

    @MainActor
    func testRetrieveWithoutRadioCanRestoreButCannotClaimRosterOrPeer() async throws {
        let key = try key(), response = try material(key), vault = CertificateMemoryVault(key: key)
        var methods: [String] = []
        let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { request in
            methods.append(request.httpMethod!); return (response, 200)
        }
        let result = await service.prepare(now: now)
        XCTAssertEqual(result.blocker, .missingBluetoothIdentity)
        XCTAssertTrue(result.diagnostics.certificateKeychainReady)
        XCTAssertFalse(result.diagnostics.peerRosterContainsThisDevice)
        XCTAssertEqual(methods, ["GET"]); XCTAssertEqual(vault.csrCalls, 0)
    }

    @MainActor
    func testNoImplicitPostWhenPrerequisitesOrConsentAreMissing() async throws {
        for local in [nil, try identity()] {
            let vault = CertificateMemoryVault()
            var methods: [String] = []
            let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { request in
                methods.append(request.httpMethod!); return (Data(), 204)
            }
            let result = await service.prepare(identity: local, now: now)
            XCTAssertEqual(result.blocker, local == nil ? .missingBluetoothIdentity : .explicitConsentRequired)
            XCTAssertEqual(methods, ["GET"])
            XCTAssertEqual(vault.csrCalls, 0); XCTAssertEqual(vault.saveCalls, 0)
            XCTAssertFalse(result.diagnostics.certificateKeychainReady)
            XCTAssertFalse(result.diagnostics.peerRosterContainsThisDevice)
        }
    }

    @MainActor
    func testUnsupportedAndAuthenticationErrorsPreserveExistingKeysMaterialAndReadiness() async throws {
        let key = try key(), data = try material(key)
        for status in [401,403,404,405,410,501,500,304,302] {
            let vault = CertificateMemoryVault(key: key, data: data)
            let before = try vault.publicKey()
            var methods: [String] = []
            let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { request in
                methods.append(request.httpMethod!); return (Data("synthetic-sensitive-error-body".utf8), status)
            }
            let result = await service.prepare(.enroll(try device()), now: now)
            XCTAssertNotNil(result.blocker)
            XCTAssertTrue(result.diagnostics.certificateKeychainReady)
            XCTAssertEqual(vault.data, data); XCTAssertEqual(try vault.publicKey(), before)
            XCTAssertEqual(methods, ["GET"]); XCTAssertEqual(vault.csrCalls, 0); XCTAssertEqual(vault.saveCalls, 0)
            XCTAssertFalse(String(describing: result.blocker).contains("sensitive"))
        }
    }

    @MainActor
    func testExistingRemoteIdentityWithoutOwnedPrivateKeyCannotResetOrImport() async throws {
        let response = try material(key()), vault = CertificateMemoryVault()
        var methods: [String] = []
        let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { request in
            methods.append(request.httpMethod!); return (response, 200)
        }
        let result = await service.prepare(.enroll(try device()), now: now)
        XCTAssertEqual(result.blocker, .existingCertificateWithoutOwnedKey)
        XCTAssertFalse(result.diagnostics.certificateKeychainReady)
        XCTAssertEqual(methods, ["GET"]); XCTAssertEqual(vault.csrCalls, 0); XCTAssertEqual(vault.saveCalls, 0)
        XCTAssertNil(vault.data)
    }

    @MainActor
    func testExpiredCacheKeepsRevisionFloorAndNeverResetsOn204() async throws {
        let key = try key(); var expiredObject = try object(key)
        var keys = expiredObject["userAesKeyList"] as! [[String: Any]]
        keys[0]["expireTime"] = 1_800_000_000_000 as Int64; expiredObject["userAesKeyList"] = keys
        expiredObject["revision"] = 10
        let expiredData = try encode(expiredObject), valid = try material(key)
        for (response, status) in [(Data(),204), (valid,200)] {
            let vault = CertificateMemoryVault(key: key, data: expiredData)
            var calls = 0
            let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { _ in
                calls += 1; return (response,status)
            }
            let result = await service.prepare(.enroll(try device()), now: now)
            XCTAssertEqual(result.blocker, status == 204 ? .invalidCertificate : .revisionRollback)
            XCTAssertFalse(result.diagnostics.certificateKeychainReady)
            XCTAssertEqual(vault.data, expiredData); XCTAssertEqual(vault.csrCalls, 0); XCTAssertEqual(vault.saveCalls, 0)
            XCTAssertEqual(calls, 1)
        }
    }

    @MainActor
    func testMalformedResponseMismatchAndPersistenceFailureDoNotClaimReadiness() async throws {
        let key = try key(), data = try material(key)
        for scenario in 0..<4 {
            let vault = CertificateMemoryVault(key: key)
            vault.failSave = scenario == 2; vault.corruptSave = scenario == 3
            let response = scenario == 0 ? Data("{}".utf8) : scenario == 1 ? try material(self.key()) : data
            let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { _ in (response,200) }
            let result = await service.prepare(identity: try identity(), now: now)
            XCTAssertNotNil(result.blocker); XCTAssertFalse(result.diagnostics.certificateKeychainReady)
            XCTAssertEqual(vault.csrCalls, 0)
            if scenario < 3 { XCTAssertNil(vault.data) }
        }
    }

    @MainActor
    func testPatchIsExplicitAndRefreshesRosterWithGET() async throws {
        let key = try key(), response = try material(key), vault = CertificateMemoryVault(key: key, data: try material(key))
        var methods: [String] = []
        let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { request in
            methods.append(request.httpMethod!)
            return request.httpMethod == "PATCH" ? (Data(),204) : (response,200)
        }
        let result = await service.patch(.irk(try identity()), now: now)
        XCTAssertEqual(methods, ["GET", "PATCH", "GET"])
        XCTAssertNil(result.blocker); XCTAssertTrue(result.diagnostics.peerRosterContainsThisDevice)
        XCTAssertTrue(result.diagnostics.certificateKeychainReady)
        XCTAssertEqual(vault.csrCalls, 0)
    }

    @MainActor
    func testFailedPostRetainsStagedKeyAndRetryStartsWithGET() async throws {
        let key = try key(), vault = CertificateMemoryVault(key: key)
        let before = try vault.publicKey()
        var methods: [String] = []
        let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { request in
            methods.append(request.httpMethod!)
            return request.httpMethod == "GET" ? (Data(),204) : (Data(),403)
        }
        for _ in 0..<2 {
            let result = await service.prepare(.enroll(try device()), now: now)
            XCTAssertEqual(result.blocker, .authRejected)
            XCTAssertFalse(result.diagnostics.certificateKeychainReady)
        }
        XCTAssertEqual(methods, ["GET","POST","GET","POST"])
        XCTAssertEqual(try vault.publicKey(), before); XCTAssertNil(vault.data); XCTAssertEqual(vault.saveCalls, 0)
    }

    @MainActor
    func testMissingDeviceMetadataCannotCreateKeyOrPost() async throws {
        let vault = CertificateMemoryVault(), incomplete = try C.Device(model: "", name: "Offline", type: "", identity: identity())
        var methods: [String] = []
        let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { request in
            methods.append(request.httpMethod!); return (Data(),204)
        }
        let result = await service.prepare(.enroll(incomplete), now: now)
        XCTAssertEqual(result.blocker, .missingDeviceMetadata)
        XCTAssertEqual(methods, ["GET"]); XCTAssertEqual(vault.csrCalls, 0); XCTAssertEqual(vault.saveCalls, 0)
    }

    @MainActor
    func testPatchCannotProceedAfterAuthFailureDespiteCachedReadiness() async throws {
        let key = try key(), original = try material(key), vault = CertificateMemoryVault(key: key, data: original)
        var methods: [String] = []
        let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { request in
            methods.append(request.httpMethod!); return (Data(),401)
        }
        let result = await service.patch(.irk(try identity()), now: now)
        XCTAssertEqual(result.blocker, .authRejected)
        XCTAssertEqual(methods, ["GET"]); XCTAssertEqual(vault.data, original); XCTAssertEqual(vault.saveCalls, 0)
    }

    @MainActor
    func testRosterMismatchDoesNotBecomePeerAuthentication() async throws {
        let key = try key(), response = try material(key), vault = CertificateMemoryVault(key: key)
        let other = try C.LocalIdentity(verifiedLocalBluetoothAddress: "22:34:56:78:9A:BC", controllerCoherentIRK: Data(repeating: 0x41, count: 16))
        let service = SamsungCloudCertificateEnrollment(session: try session(), context: try context(), vault: vault) { _ in (response,200) }
        let result = await service.prepare(identity: other, now: now)
        XCTAssertFalse(result.diagnostics.certificateKeychainReady)
        XCTAssertNil(vault.data); XCTAssertEqual(vault.saveCalls, 0)
        XCTAssertFalse(result.diagnostics.peerRosterContainsThisDevice)
        XCTAssertEqual(result.blocker, .peerRosterMismatch)
        XCTAssertEqual(result.diagnostics.publicValues["peer_authenticated"], false)
    }
}
