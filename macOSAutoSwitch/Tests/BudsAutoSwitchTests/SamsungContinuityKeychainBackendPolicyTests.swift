import Foundation
import Security
import XCTest
@testable import BudsAutoSwitch

/// Pure policy/dictionary tests only: never instantiate a default runtime
/// backend, construct SecAccess, read signing information, or call SecItem*.
final class SamsungContinuityKeychainBackendPolicyTests: XCTestCase {
    typealias B = SamsungContinuityKeychainBackend
    private let appID = "SYNTHETIC.io.example.buds"
    private func backend(_ entitlements: [String: Any]) -> B {
        B(selection: B.select(entitlements: entitlements))
    }
    func testNoKeychainEntitlementsSelectFileWithoutAnOperationFailure() throws {
        for entitlements: [String: Any] in [[:], ["com.apple.security.app-sandbox": false]] {
            let selected = B.select(entitlements: entitlements)
            XCTAssertEqual(selected.kind, .file)
            XCTAssertEqual(selected.status, errSecSuccess)
            XCTAssertNil(selected.accessGroup)
        }
    }
    func testEitherApplicationIdentifierSpellingEnablesOwnDPGroup() {
        for key in ["application-identifier", "com.apple.application-identifier"] {
            let selected = B.select(entitlements: [key: appID])
            XCTAssertEqual(selected.kind, .dataProtection)
            XCTAssertEqual(selected.accessGroup, appID)
        }
    }
    func testEntitledGroupUsesOwnApplicationEvenWhenSharedGroupIsFirst() throws {
        let selected = backend(["com.apple.application-identifier": appID,
            "keychain-access-groups": ["SYNTHETIC.shared", appID]])
        let query = try selected.query([:])
        XCTAssertEqual(query[kSecAttrAccessGroup as String] as? String, appID)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }
    func testMalformedEntitlementsFailClosedInsteadOfChoosingFile() {
        let invalid: [[String: Any]] = [
            ["application-identifier": ""], ["application-identifier": true],
            ["application-identifier": "TEAM.*"], ["application-identifier": "TEAM.bad\n"],
            ["application-identifier": appID, "com.apple.application-identifier": "OTHER.app"],
            ["keychain-access-groups": [appID]],
            ["application-identifier": appID, "keychain-access-groups": []],
            ["application-identifier": appID, "keychain-access-groups": "invalid"],
            ["application-identifier": appID, "keychain-access-groups": ["TEAM.shared"]],
            ["application-identifier": appID, "keychain-access-groups": [appID, "*"]]
        ]
        for entitlements in invalid {
            let selected = B.select(entitlements: entitlements)
            XCTAssertEqual(selected.kind, .unavailable)
            XCTAssertEqual(selected.status, errSecMissingEntitlement)
            XCTAssertNil(selected.accessGroup)
        }
    }
    func testFileQueriesExplicitlyDisableDPAndOmitDPSyncAndProtectionAttributes() throws {
        let query = try backend([:]).query([kSecClass as String: kSecClassGenericPassword,
            kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrAccessGroup as String: "SYNTHETIC.other"])
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, false)
        for key in [kSecAttrSynchronizable, kSecAttrAccessible, kSecAttrAccessControl, kSecAttrAccessGroup] {
            XCTAssertNil(query[key as String])
        }
    }
    func testFileNamespaceCannotReadTheExistingDPOrLegacyAccountNamespaces() {
        let file = backend([:]), dp = backend(["application-identifier": appID])
        for base in ["io.github.galaxybudsclient.certificate-v1.KC01",
                     "io.github.galaxybudsclient.continuity.outgoing-classic.v1"] {
            XCTAssertEqual(dp.service(base), base)
            XCTAssertEqual(file.service(base), base + ".file-creator-acl.v1")
            XCTAssertNotEqual(file.service(base), dp.service(base))
        }
    }
    func testDPAddsDeviceOnlyNonsyncProtectionAndNoLegacyACL() throws {
        let protection = try backend(["application-identifier": appID]).creationProtection()
        XCTAssertEqual(protection[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(protection[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(protection[kSecAttrAccessGroup as String] as? String, appID)
        XCTAssertNil(protection[kSecAttrAccess as String])
    }
    func testUnavailableBackendRejectsBeforeAnySecurityOperation() {
        let invalid = backend(["application-identifier": "*"])
        XCTAssertThrowsError(try invalid.query([:]))
        XCTAssertThrowsError(try invalid.creationProtection())
        XCTAssertEqual(B.diagnosticSnapshot?.operation, .selection)
        XCTAssertEqual(B.diagnosticSnapshot?.status, errSecMissingEntitlement)
    }
    func testMissingOwnGroupInInjectedDPSelectionCannotTrapOrUseDefaultSharedGroup() {
        let invalid = B(selection: .init(kind: .dataProtection, accessGroup: nil, status: errSecSuccess))
        XCTAssertThrowsError(try invalid.query([:]))
        XCTAssertThrowsError(try invalid.creationProtection())
        XCTAssertEqual(B.diagnosticSnapshot?.status, errSecMissingEntitlement)
    }
    func testCreatorACLRejectsWildcardEmptyForeignAndAdditionalApps() {
        let own = Data("synthetic-current-app".utf8), other = Data("synthetic-other-app".utf8)
        XCTAssertTrue(B.creatorOnly([own], own: own))
        XCTAssertFalse(B.creatorOnly(nil, own: own))
        XCTAssertFalse(B.creatorOnly([], own: own))
        XCTAssertFalse(B.creatorOnly([other], own: own))
        XCTAssertFalse(B.creatorOnly([own, other], own: own))
        XCTAssertFalse(B.creatorOnly([own, own], own: own))
        XCTAssertFalse(B.creatorOnly([Data()], own: Data()))
    }
    func testPartitionIntegrityOnlyExceptionCannotHideWildcardSecretAccess() {
        let partition = kSecACLAuthorizationPartitionID as String
        let integrity = kSecACLAuthorizationIntegrity as String
        XCTAssertTrue(B.metadataOnly([partition]))
        XCTAssertTrue(B.metadataOnly([integrity, partition]))
        XCTAssertFalse(B.metadataOnly([]))
        for grant in [kSecACLAuthorizationAny, kSecACLAuthorizationDecrypt,
                      kSecACLAuthorizationSign, kSecACLAuthorizationChangeACL] {
            XCTAssertFalse(B.metadataOnly([partition, grant as String]))
            XCTAssertFalse(B.metadataOnly([grant as String]))
        }
        XCTAssertFalse(B.metadataOnly(["unknown"]))
    }
    private var validKeyAttributes: [String: Any] {
        [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
         kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
         kSecAttrKeySizeInBits as String: 2048, kSecAttrIsExtractable as String: false]
    }
    func testRSARequiresExplicitNonextractablePrivate2048Attributes() {
        let valid = validKeyAttributes
        XCTAssertTrue(B.keyIsPrivateNonextractableRSA2048(valid))
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            XCTAssertFalse(B.keyIsPrivateNonextractableRSA2048(missing))
        }
        for (key, value): (CFString, Any) in [(kSecAttrIsExtractable, true),
            (kSecAttrKeySizeInBits, 1024), (kSecAttrKeyType, kSecAttrKeyTypeECSECPrimeRandom),
            (kSecAttrKeyClass, kSecAttrKeyClassPublic)] {
            var bad = valid; bad[key as String] = value
            XCTAssertFalse(B.keyIsPrivateNonextractableRSA2048(bad))
        }
    }
    func testLegacyNumericRSAEnumAttributesAreSupportedWithoutExport() {
        var file = validKeyAttributes
        file[kSecAttrKeyType as String] = NSNumber(value: Int(kSecAttrKeyTypeRSA as String)!)
        file[kSecAttrKeyClass as String] = NSNumber(value: Int(kSecAttrKeyClassPrivate as String)!)
        XCTAssertTrue(B.keyIsPrivateNonextractableRSA2048(file))
    }
    func testFailureNeverChangesBackendAndDiagnosticsContainOnlyClosedFields() throws {
        let dp = backend(["application-identifier": appID])
        XCTAssertEqual(dp.fail(.keyCreate, errSecMissingEntitlement), .keychainUnavailable)
        XCTAssertEqual(dp.selection.kind, .dataProtection)
        XCTAssertEqual(try dp.query([:])[kSecUseDataProtectionKeychain as String] as? Bool, true)
        let diagnostic = try XCTUnwrap(B.diagnosticSnapshot)
        XCTAssertEqual(diagnostic.backend, .dataProtection)
        XCTAssertEqual(diagnostic.status, errSecMissingEntitlement)
        XCTAssertEqual(Set(diagnostic.publicValues.keys), ["continuity_keychain_backend",
            "continuity_keychain_operation", "continuity_keychain_osstatus"])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: diagnostic.publicValues), as: UTF8.self)
        XCTAssertFalse(encoded.contains(appID))
        XCTAssertFalse(encoded.contains("secret"))
    }
}
