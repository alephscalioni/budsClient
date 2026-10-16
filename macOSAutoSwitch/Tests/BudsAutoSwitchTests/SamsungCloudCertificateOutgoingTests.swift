import XCTest
@testable import BudsAutoSwitch

extension SamsungCloudCertificateTests {
    func outgoingAccount() -> [String: Any] {
        ["token_response": ["userId": "synthetic-user", "access_token": "synthetic-account-token"],
         "installation_id": String(repeating: "a", count: 32),
         "cloud_registration": ["dvcId": deviceID, "tokens": [["type": "user", "accessToken": "synthetic-common-cloud-user"]]]]
    }
    var outgoingERS: Data { Data(#"{"default":"https://api.samsungcloud.com","play":"https://play.samsungcloud.com"}"#.utf8) }
    func outgoingIdentity(_ store: ContinuityMemoryStore, create: Bool = true) throws -> C.LocalIdentity {
        try SamsungContinuityLocalIdentity(session: C.Session.account(outgoingAccount()), installationID: String(repeating: "a", count: 32),
            address: { "12:34:56:78:9A:BC" }, store: store, random: { Data(repeating: 0x41, count: 16) }).load(create: create)
    }
    @MainActor
    func testOutgoingFactoryOwnMetadataCommonCloudBearerAnd204CSRGate() async throws {
        let key = try key(), response = try material(key), vault = CertificateMemoryVault(key: key)
        let store = ContinuityMemoryStore(); var requests: [URLRequest] = []
        let account = outgoingAccount(), original = try encode(account)
        let result = await SamsungCloudProtocol.enrollContinuity(account: account,
            address: { "12:34:56:78:9A:BC" }, identityStore: store, random: { Data(repeating: 0x41, count: 16) },
            name: { "Offline Mac" }, transport: { request in
                requests.append(request)
                if request.url?.host == "ers.samsungcloud.com" { return (self.outgoingERS,200) }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-common-cloud-user")
                XCTAssertNil(request.value(forHTTPHeaderField: "x-sc-access-token"))
                if request.httpMethod == "GET" { return (Data(),204) }
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let info = try XCTUnwrap(body["deviceInfo"] as? [String: String])
                XCTAssertEqual(info, ["deviceModel":"960XGL", "deviceName":"Offline Mac", "deviceType":"pc",
                                     "btAddr":"12:34:56:78:9A:BC", "irk":Data(repeating:0x41,count:16).base64EncodedString()])
                let csr = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(body["csr"] as? String)))
                try SamsungCloudCertificateDER.validateCSR(csr, deviceID: self.deviceID)
                return (response,201)
            }, vault: { _ in vault })
        XCTAssertNil(result.blocker); XCTAssertEqual(result.stage, .postKC01); XCTAssertEqual(result.httpStatus, 201)
        XCTAssertEqual(requests.map { $0.httpMethod! }, ["GET","GET","POST"])
        XCTAssertEqual(vault.csrCalls,1); XCTAssertEqual(store.inserts,1)
        XCTAssertEqual(result.publicValues["continuity_identity_mode"] as? String,"outgoing_classic_application")
        XCTAssertEqual(result.publicValues["continuity_outgoing_only"] as? Bool,true)
        XCTAssertEqual(result.publicValues["continuity_incoming_ble_discovery_available"] as? Bool,false)
        XCTAssertEqual(result.publicValues["peer_authenticated"] as? Bool,false)
        XCTAssertEqual(result.publicValues["native_switch_validated"] as? Bool,false)
        XCTAssertEqual(try encode(account),original)
    }
    @MainActor
    func testOutgoingFactoryExistingCertificateMissingOwnedKeyNeverPostsOrReplaces() async throws {
        let response = try material(key()), vault = CertificateMemoryVault(), store = ContinuityMemoryStore()
        var methods: [String] = []
        let result = await SamsungCloudProtocol.enrollContinuity(account: outgoingAccount(), address: { "12:34:56:78:9A:BC" },
            identityStore: store, random: { Data(repeating:0x41,count:16) }, name: { "Mac" }, transport: { request in
                methods.append(request.httpMethod!)
                return request.url?.host == "ers.samsungcloud.com" ? (self.outgoingERS,200) : (response,200)
            }, vault: { _ in vault })
        XCTAssertEqual(result.blocker,.existingCertificateWithoutOwnedKey)
        XCTAssertEqual(methods,["GET","GET"]); XCTAssertEqual(vault.csrCalls,0); XCTAssertNil(vault.data)
        XCTAssertFalse(result.humanStatus.contains("existingCertificateWithoutOwnedKey"))
        XCTAssertTrue(result.humanStatus.contains("chave privada"))
    }
    @MainActor
    func testFactoryMissingCloudTokenAndInvalidAddressCannotReachNetworkOrCreateCertificate() async throws {
        var missingCloud = outgoingAccount(); missingCloud["cloud_registration"] = ["dvcId": deviceID, "tokens": []]
        for (account,address,expected) in [(missingCloud,"12:34:56:78:9A:BC",C.Failure.missingCloudToken),
                                          (outgoingAccount(),"00:00:00:00:00:00",C.Failure.missingBluetoothIdentity)] {
            let store = ContinuityMemoryStore(), vault = CertificateMemoryVault()
            let result = await SamsungCloudProtocol.enrollContinuity(account: account,address: { address },identityStore: store,
                random: { XCTFail("no draw"); return Data() }, transport: { _ in XCTFail("no HTTP"); return (Data(),500) },vault: { _ in vault })
            XCTAssertEqual(result.blocker,expected); XCTAssertEqual(store.inserts,0); XCTAssertEqual(vault.csrCalls,0)
        }
    }
    @MainActor
    func testPrepareFactoryRemainsGETOnlyEvenOn204() async throws {
        let vault = CertificateMemoryVault(); var methods: [String] = []
        let result = await SamsungCloudProtocol.prepareCertificates(account: outgoingAccount(),transport: { request in
            methods.append(request.httpMethod!)
            return request.url?.host == "ers.samsungcloud.com" ? (self.outgoingERS,200) : (Data(),204)
        },vault: { _ in vault })
        XCTAssertEqual(methods,["GET","GET"]); XCTAssertEqual(vault.csrCalls,0); XCTAssertEqual(vault.saveCalls,0)
        XCTAssertEqual(result.blocker,.missingBluetoothIdentity); XCTAssertEqual(result.stage,.getKC01); XCTAssertEqual(result.httpStatus,204)
    }
    @MainActor
    func testSanitizedServiceCodeAllowlistAndPublicOutput() async throws {
        typealias E = SamsungCloudCertificateEnrollment
        for field in ["errorCode","code","error_code"] {
            XCTAssertEqual(E.serviceCode(try encode([field:"CA_NOT_ALLOWED","message":"private body"])),"CA_NOT_ALLOWED")
        }
        for bad in ["x", "A", "lowercase", "ERROR with space", "ERR\n", "HTTP://PRIVATE", String(repeating:"A",count:65)] {
            XCTAssertNil(E.serviceCode(try encode(["errorCode":bad])))
        }
        for object: [String: Any] in [["message":"PRIVATE"],["errorCode":42],["error":["code":"PRIVATE"]]] {
            XCTAssertNil(E.serviceCode(try encode(object)))
        }
        XCTAssertNil(E.serviceCode(Data(repeating:65,count:65_537)))
        let vault = CertificateMemoryVault()
        let service = E(session: try session(),context: try context(),vault:vault) { _ in
            (Data(#"{"errorCode":"CA_NOT_ALLOWED","message":"synthetic-private-account-and-key"}"#.utf8),403)
        }
        let result = await service.prepare(identity: try identity(),now:now)
        XCTAssertEqual(result.httpStatus,403); XCTAssertEqual(result.stage,.getKC01); XCTAssertEqual(result.serviceCode,"CA_NOT_ALLOWED")
        let publicJSON = String(decoding:try encode(result.publicValues),as:UTF8.self)
        for secret in ["synthetic-private","synthetic-cloud", "12:34:56", "QUFB"] { XCTAssertFalse(publicJSON.contains(secret)) }
        XCTAssertFalse(result.humanStatus.contains("authRejected"))
    }
    @MainActor
    func testERSAndPOSTFailureStageStatusAndCode() async throws {
        for failERS in [true,false] {
            let vault = CertificateMemoryVault(key:try key())
            let result = await SamsungCloudProtocol.enrollContinuity(account:outgoingAccount(),address:{ "12:34:56:78:9A:BC" },
                identityStore:ContinuityMemoryStore(),random:{ Data(repeating:0x41,count:16) },transport:{ request in
                    if request.url?.host == "ers.samsungcloud.com" {
                        return failERS ? (Data(#"{"code":"ERS_REFUSED"}"#.utf8),503) : (self.outgoingERS,200)
                    }
                    return request.httpMethod == "GET" ? (Data(),204) : (Data(#"{"error_code":"CA_REFUSED","message":"private"}"#.utf8),403)
                },vault:{ _ in vault })
            XCTAssertEqual(result.stage,failERS ? .ers : .postKC01); XCTAssertEqual(result.httpStatus,failERS ? 503 : 403)
            XCTAssertEqual(result.serviceCode,failERS ? "ERS_REFUSED" : "CA_REFUSED"); XCTAssertNil(vault.data)
        }
    }
    @MainActor
    func testRosterMismatchPreservesPreviouslyOwnedMaterial() async throws {
        let key = try key(), original = try material(key), vault = CertificateMemoryVault(key:key,data:original)
        var changed = try object(key), peers = changed["deviceInfoList"] as! [[String:Any]]
        peers[0]["irk"] = Data(repeating:0x42,count:16).base64EncodedString(); changed["deviceInfoList"] = peers
        let response = try encode(changed)
        let service = SamsungCloudCertificateEnrollment(session:try session(),context:try context(),vault:vault) { _ in (response,200) }
        let result = await service.prepare(.enroll(try device()),now:now)
        XCTAssertEqual(result.blocker,.peerRosterMismatch); XCTAssertEqual(vault.data,original); XCTAssertEqual(vault.saveCalls,0)
    }
    @MainActor
    func testMalformedCSRNeverPostsAndReportsGET204() async throws {
        final class BadCSR: SamsungCloudCertificateVault {
            var creates = 0
            func publicKey() throws -> Data? { nil }
            func readMaterial() throws -> Data? { nil }
            func saveMaterial(_ data: Data) throws { XCTFail("no save") }
            func createCSR(deviceID: String) throws -> Data { creates += 1; return Data([1]) }
        }
        let vault = BadCSR(); var methods:[String] = []
        let service = SamsungCloudCertificateEnrollment(session:try session(),context:try context(),vault:vault) { request in
            methods.append(request.httpMethod!); return (Data(),204)
        }
        let result = await service.prepare(.enroll(try device()),now:now)
        XCTAssertNotNil(result.blocker); XCTAssertEqual(methods,["GET"]); XCTAssertEqual(vault.creates,1)
    }
    func testPreparedMaterialOnlyAfterOwnedCertificateLocalBindingAndFirstUnexpiredKey() throws {
        let key = try key(); var object = try object(key)
        let keys = object["userAesKeyList"] as! [[String:Any]]
        var expired = keys[0]; expired["expireTime"] = 1_700_000_000_000 as Int64
        var later = keys[0]; later["expireTime"] = 2_000_000_000_000 as Int64
        later["aes256Key"] = Data(repeating:0x44,count:32).base64EncodedString()
        object["userAesKeyList"] = [expired] + keys + [later]
        var peers = object["deviceInfoList"] as! [[String:Any]]
        let phone:[String:Any] = ["dvcId":"synthetic-phone","deviceType":"phone","deviceName":"Real roster name",
            "deviceModel":"SM-SYNTHETIC","btAddr":"22:34:56:78:9A:BC","irk":Data(repeating:0x45,count:16).base64EncodedString()]
        var pc = phone; pc["dvcId"] = "synthetic-pc"; pc["deviceType"] = "pc"
        peers += [phone,pc]; object["deviceInfoList"] = peers
        let store = ContinuityMemoryStore(); _ = try outgoingIdentity(store)
        let vault = CertificateMemoryVault(key:key,data:try encode(object))
        let material = try SamsungCloudProtocol.loadPreparedPeerMaterial(account:outgoingAccount(),address:{ "12:34:56:78:9A:BC" },
            identityStore:store,vault:{ _ in vault },now:now)
        XCTAssertEqual(material.ownClassicAddress,"12:34:56:78:9A:BC"); XCTAssertEqual(material.revision,7)
        XCTAssertEqual(material.accountKey.bytes,Data(repeating:0x43,count:32))
        XCTAssertEqual(material.accountKey.expireTime,1_900_000_000_000)
        XCTAssertEqual(material.phones.count,1); XCTAssertEqual(material.phones.first?.name,"Real roster name")
        XCTAssertEqual(material.phones.first?.model,"SM-SYNTHETIC"); XCTAssertEqual(material.phones.first?.address,"22:34:56:78:9A:BC")
        XCTAssertEqual(material.identityMode,.outgoingClassicApplication); XCTAssertTrue(material.outgoingOnly)
        for value in [String(reflecting:material),String(describing:material),String(reflecting:material.accountKey)] {
            XCTAssertFalse(value.contains("Q0ND")); XCTAssertFalse(value.contains("SM-SYNTHETIC")); XCTAssertFalse(value.contains("12:34"))
        }
        XCTAssertEqual(Mirror(reflecting:material.accountKey).children.count,0)
        XCTAssertEqual(store.inserts,1); XCTAssertEqual(vault.csrCalls,0); XCTAssertEqual(vault.saveCalls,0)
        // Different installation/address, expired material, missing owned key,
        // and a changed application identity can never leak a KU handoff.
        vault.key = nil
        assertFailure(.existingCertificateWithoutOwnedKey) {
            _ = try C.preparedPeerMaterial(session:session(),identity:outgoingIdentity(store,create:false),vault:vault,now:now)
        }
        vault.key = key
        assertFailure(.expired) {
            _ = try C.preparedPeerMaterial(session:session(),identity:outgoingIdentity(store,create:false),vault:vault,now:Date(timeIntervalSince1970:2_100_000_000))
        }
        let wrong = try C.LocalIdentity.outgoingClassicApplication(ownClassicAddress:"12:34:56:78:9A:BC",applicationIdentity:Data(repeating:0x46,count:16))
        assertFailure(.peerRosterMismatch) { _ = try C.preparedPeerMaterial(session:session(),identity:wrong,vault:vault,now:now) }
        XCTAssertThrowsError(try SamsungCloudProtocol.loadPreparedPeerMaterial(account:outgoingAccount(),address:{ "32:34:56:78:9A:BC" },identityStore:store,vault:{ _ in vault },now:now))
    }
}

extension SamsungCloudCertificateTests {
    @MainActor
    func testForeignCSRKeyCannotBeSubmittedAsOwnedCSR() async throws {
        final class ForeignCSR: SamsungCloudCertificateVault {
            let csr: Data
            let owned: Data
            init(csr: Data, owned: Data) { self.csr = csr; self.owned = owned }
            func publicKey() throws -> Data? { owned }
            func readMaterial() throws -> Data? { nil }
            func createCSR(deviceID: String) throws -> Data { csr }
            func saveMaterial(_ data: Data) throws { XCTFail("must not save") }
        }
        let csr = try SamsungCloudCertificateDER.csr(deviceID:deviceID,privateKey:key())
        let vault = try ForeignCSR(csr:csr,owned:publicData(key()))
        var methods:[String] = []
        let service = SamsungCloudCertificateEnrollment(session:try session(),context:try context(),vault:vault) { request in
            methods.append(request.httpMethod!); return (Data(),204)
        }
        let result = await service.prepare(.enroll(try device()),now:now)
        XCTAssertEqual(result.blocker,.invalidCSR); XCTAssertEqual(methods,["GET"])
        XCTAssertEqual(result.httpStatus,204); XCTAssertEqual(result.stage,.getKC01)
    }
    @MainActor
    func testAcceptedPOSTCannotClaimReadyBeforeKeychainReadback() async throws {
        let key = try key(), response = try material(key), vault = CertificateMemoryVault(key:key)
        vault.corruptSave = true
        let service = SamsungCloudCertificateEnrollment(session:try session(),context:try context(),vault:vault) { request in
            request.httpMethod == "GET" ? (Data(),204) : (response,201)
        }
        let result = await service.prepare(.enroll(try device()),now:now)
        XCTAssertEqual(result.blocker,.keychainUnavailable); XCTAssertEqual(result.httpStatus,201); XCTAssertEqual(result.stage,.postKC01)
        XCTAssertFalse(result.diagnostics.certificateKeychainReady)
        XCTAssertNotEqual(result.humanStatus,"Continuidade preparada")
    }
    @MainActor
    func testExplicitPatchFailurePreservesMaterialAndSanitizesObservability() async throws {
        let key = try key(), original = try material(key), vault = CertificateMemoryVault(key:key,data:original)
        let service = SamsungCloudCertificateEnrollment(session:try session(),context:try context(),vault:vault) { request in
            request.httpMethod == "GET" ? (original,200) : (Data(#"{"errorCode":"PATCH_DENIED","message":"private"}"#.utf8),403)
        }
        let result = await service.patch(.irk(try identity()),now:now)
        XCTAssertEqual(result.stage,.patchDevice); XCTAssertEqual(result.httpStatus,403); XCTAssertEqual(result.serviceCode,"PATCH_DENIED")
        // GET refresh can canonicalize the encoding; compare decoded material.
        XCTAssertEqual(try JSONSerialization.jsonObject(with:XCTUnwrap(vault.data)) as? NSDictionary,
                       try JSONSerialization.jsonObject(with:original) as? NSDictionary)
        XCTAssertEqual(result.blocker,.authRejected); XCTAssertEqual(vault.csrCalls,0)
    }
    func testPreparedMaterialRejectsWrongOwnedKeyAndControllerMode() throws {
        let key = try key(), vault = CertificateMemoryVault(key:try self.key(),data:try material(key))
        let store = ContinuityMemoryStore(), outgoing = try outgoingIdentity(store)
        assertFailure(.keyMismatch) { _ = try C.preparedPeerMaterial(session:session(),identity:outgoing,vault:vault,now:now) }
        vault.key = key
        assertFailure(.continuityIdentityMismatch) { _ = try C.preparedPeerMaterial(session:session(),identity:identity(),vault:vault,now:now) }
        XCTAssertThrowsError(try SamsungCloudProtocol.loadPreparedPeerMaterial(account:outgoingAccount(),address:{ "12:34:56:78:9A:BC" },
            identityStore:ContinuityMemoryStore(),vault:{ _ in vault },now:now))
    }
}
