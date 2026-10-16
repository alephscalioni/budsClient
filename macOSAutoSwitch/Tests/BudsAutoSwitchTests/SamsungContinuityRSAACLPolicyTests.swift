import Foundation
import Security
import XCTest
@testable import BudsAutoSwitch

/// No live signature, Keychain, SecAccess or RSA generator calls. Authorization
/// fixtures model untrusted ACL metadata; trusted-app bytes are synthetic.
final class SamsungContinuityRSAACLPolicyTests: XCTestCase {
    typealias B = SamsungContinuityKeychainBackend
    private let own = Data("synthetic-self".utf8)
    private let other = Data("synthetic-other".utf8)
    private func row(_ auth: [CFString], _ apps: [Data]?, purpose: B.ACLPurpose = .privateRSA) -> B.ACLDiagnostic {
        B.assessACL(auth.map { $0 as String }, applications: apps, own: own, purpose: purpose)
    }
    func testEmptyOwnerEntryRequiresUserAuthorizationAndCannotStandInForSigningGrant() {
        let owner = row([kSecACLAuthorizationChangeACL], [])
        XCTAssertEqual(owner.reason, .allowed)
        XCTAssertFalse(owner.currentAppMatch)
        XCTAssertEqual(B.finishACLAssessment([owner], purpose: .privateRSA, aclCount: 1)?.reason, .missingOwnedGrant)
        let signing = row([kSecACLAuthorizationSign], [own])
        XCTAssertNil(B.finishACLAssessment([owner, signing], purpose: .privateRSA, aclCount: 2))
        XCTAssertEqual(row([kSecACLAuthorizationChangeACL], nil).reason, .wildcardSensitiveApps)
        XCTAssertEqual(row([kSecACLAuthorizationChangeACL, kSecACLAuthorizationSign], []).reason, .emptySensitiveApps)
        XCTAssertEqual(row([kSecACLAuthorizationChangeOwner], []).reason, .emptySensitiveApps)
    }

    func testPublicEncryptionDoesNotGrantPrivateSigningOrSecretRead() {
        let publicRow = row([kSecACLAuthorizationEncrypt], nil)
        XCTAssertEqual(publicRow.reason, .allowed)
        XCTAssertEqual(publicRow.publicCount, 1)
        XCTAssertEqual(publicRow.sensitiveCount, 0)
        XCTAssertTrue(publicRow.wildcard)
        XCTAssertFalse(publicRow.currentAppMatchEvaluated)
        let signRow = row([kSecACLAuthorizationSign], [own])
        XCTAssertNil(B.finishACLAssessment([publicRow, signRow], purpose: .privateRSA, aclCount: 2))
        XCTAssertEqual(B.finishACLAssessment([publicRow], purpose: .privateRSA, aclCount: 1)?.reason, .missingOwnedGrant)
    }
    func testMetadataAndPublicOnlyMixedACLIsNotPrivateAccess() {
        let mixed = row([kSecACLAuthorizationEncrypt, kSecACLAuthorizationPartitionID, kSecACLAuthorizationIntegrity], nil)
        XCTAssertEqual(mixed.reason, .allowed)
        XCTAssertEqual(mixed.publicCount, 1)
        XCTAssertEqual(mixed.metadataCount, 2)
        XCTAssertEqual(mixed.sensitiveCount, 0)
        XCTAssertEqual(B.finishACLAssessment([mixed], purpose: .privateRSA, aclCount: 1)?.reason, .missingOwnedGrant)
    }
    func testGenericSecretsAndNewAccessDoNotUseRSAPublicException() {
        for purpose: B.ACLPurpose in [.genericSecret, .creation] {
            XCTAssertEqual(row([kSecACLAuthorizationEncrypt], nil, purpose: purpose).reason, .wildcardSensitiveApps)
            XCTAssertEqual(row([kSecACLAuthorizationEncrypt], [own], purpose: purpose).reason, .allowed)
        }
    }
    func testEveryKnownSecretOrControlGrantStillRejectsWildcard() {
        for grant in [kSecACLAuthorizationAny, kSecACLAuthorizationSign, kSecACLAuthorizationDecrypt,
                      kSecACLAuthorizationKeychainItemRead, kSecACLAuthorizationDerive, kSecACLAuthorizationMAC,
                      kSecACLAuthorizationExportClear, kSecACLAuthorizationExportWrapped,
                      kSecACLAuthorizationChangeACL, kSecACLAuthorizationChangeOwner,
                      kSecACLAuthorizationKeychainItemModify, kSecACLAuthorizationDelete] {
            XCTAssertEqual(row([grant], nil).reason, .wildcardSensitiveApps)
            XCTAssertEqual(row([grant, kSecACLAuthorizationEncrypt], nil).reason, .wildcardSensitiveApps)
            XCTAssertEqual(row([grant, kSecACLAuthorizationPartitionID], nil).reason, .wildcardSensitiveApps)
            XCTAssertEqual(row([grant], [own]).reason, .allowed)
        }
    }
    func testUnknownAuthorizationsAreSensitiveAndNeverSkipped() {
        let unknown = B.assessACL(["synthetic-unknown"], applications: nil, own: own, purpose: .privateRSA)
        XCTAssertEqual(unknown.reason, .wildcardSensitiveApps)
        XCTAssertEqual(unknown.unknownCount, 1)
        XCTAssertEqual(unknown.sensitiveCount, 1)
    }
    func testEmptyAuthorizationListHasDistinctReason() {
        XCTAssertEqual(row([], nil).reason, .emptyAuthorizations)
        XCTAssertEqual(row([], [own]).reason, .emptyAuthorizations)
    }
    func testDistinctFailuresAndCurrentAppBooleanDoNotAdmitAdditionalApps() {
        XCTAssertEqual(row([kSecACLAuthorizationSign], []).reason, .emptySensitiveApps)
        XCTAssertEqual(row([kSecACLAuthorizationSign], [other]).reason, .currentAppMismatch)
        let extra = row([kSecACLAuthorizationSign], [own, other])
        XCTAssertEqual(extra.reason, .multipleSensitiveApps)
        XCTAssertTrue(extra.currentAppMatch)
        XCTAssertEqual(extra.applicationCount, 2)
        XCTAssertEqual(row([kSecACLAuthorizationSign], [own, own]).reason, .multipleSensitiveApps)
    }
    func testCreatorDecryptDoesNotSubstituteForOwnedRSASigningGrant() {
        let decrypt = row([kSecACLAuthorizationDecrypt], [own])
        XCTAssertEqual(B.finishACLAssessment([decrypt], purpose: .privateRSA, aclCount: 1)?.reason, .missingOwnedSigningGrant)
        XCTAssertNil(B.finishACLAssessment([decrypt], purpose: .genericSecret, aclCount: 1))
        XCTAssertNil(B.finishACLAssessment([row([kSecACLAuthorizationAny], [own])], purpose: .privateRSA, aclCount: 1))
    }
    func testPrivateRSAContextRequiresPrivateRSAAttributes() {
        let privateRSA: [String: Any] = [kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                                        kSecAttrKeyType as String: kSecAttrKeyTypeRSA]
        XCTAssertTrue(B.keyIsPrivateRSA(privateRSA))
        var wrong = privateRSA; wrong[kSecAttrKeyClass as String] = kSecAttrKeyClassPublic
        XCTAssertFalse(B.keyIsPrivateRSA(wrong))
        wrong = privateRSA; wrong[kSecAttrKeyType as String] = kSecAttrKeyTypeECSECPrimeRandom
        XCTAssertFalse(B.keyIsPrivateRSA(wrong))
        XCTAssertFalse(B.keyIsPrivateRSA([:]))
    }
    func testFileGenerationSuppliesSameAccessAtTopAndPrivateLevelsWithoutOtherChanges() throws {
        // An identity-bearing in-memory marker tests placement, not SecAccess.
        let marker = NSObject()
        let privateAttrs: [String: Any] = [kSecAttrAccess as String: marker,
            kSecAttrIsExtractable as String: false, kSecAttrIsPermanent as String: true]
        let result = B.rsaGenerationAttributes(base: [kSecUseDataProtectionKeychain as String: false,
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048],
            privateAttributes: privateAttrs, purpose: .file)
        XCTAssertTrue(result[kSecAttrAccess as String] as? NSObject === marker)
        XCTAssertEqual(result[kSecAttrIsExtractable as String] as? Bool, false)
        let nested = try XCTUnwrap(result[kSecPrivateKeyAttrs as String] as? [String: Any])
        XCTAssertTrue(nested[kSecAttrAccess as String] as? NSObject === marker)
        XCTAssertEqual(nested[kSecAttrIsExtractable as String] as? Bool, false)
        XCTAssertEqual(nested[kSecAttrIsPermanent as String] as? Bool, true)
        XCTAssertEqual(result[kSecUseDataProtectionKeychain as String] as? Bool, false)
        XCTAssertEqual(result[kSecAttrKeySizeInBits as String] as? Int, 2048)
    }
    func testDPGenerationDoesNotGainFileSecAccess() {
        let result = B.rsaGenerationAttributes(base: [kSecUseDataProtectionKeychain as String: true],
            privateAttributes: [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly], purpose: .dataProtection)
        XCTAssertNil(result[kSecAttrAccess as String])
        XCTAssertEqual(result[kSecUseDataProtectionKeychain as String] as? Bool, true)
    }
    func testFailureSnapshotIncludesClosedReasonCountsAndBooleansWithoutRawACL() throws {
        let assessment = row([kSecACLAuthorizationEncrypt, kSecACLAuthorizationSign,
            kSecACLAuthorizationDecrypt, kSecACLAuthorizationKeychainItemRead,
            kSecACLAuthorizationExportClear, kSecACLAuthorizationChangeACL], nil)
        let file = B(selection: .init(kind: .file, accessGroup: nil, status: errSecSuccess))
        _ = file.fail(.accessValidate, errSecAuthFailed, acl: assessment)
        let diagnostic = try XCTUnwrap(B.diagnosticSnapshot)
        XCTAssertEqual(diagnostic.status, -25293)
        XCTAssertEqual(diagnostic.acl?.reason, .wildcardSensitiveApps)
        XCTAssertEqual(diagnostic.acl?.signCount, 1)
        XCTAssertEqual(diagnostic.acl?.decryptCount, 1)
        XCTAssertEqual(diagnostic.acl?.readCount, 1)
        XCTAssertEqual(diagnostic.acl?.exportCount, 1)
        XCTAssertEqual(diagnostic.acl?.changeCount, 1)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: diagnostic.publicValues), as: UTF8.self)
        for forbidden in ["synthetic-self", "synthetic-other", "application-identifier", "/Applications/", "BEGIN", "authorization_names"] {
            XCTAssertFalse(json.contains(forbidden))
        }
    }
    func testDiagnosticCountsAreClampedAndReasonsCannotContainUntrustedText() {
        var diagnostic = B.ACLDiagnostic(reason: .currentAppMismatch, purpose: .privateRSA)
        diagnostic.aclIndex = -3; diagnostic.aclCount = Int.max; diagnostic.applicationCount = Int.max
        XCTAssertEqual(diagnostic.publicValues["continuity_keychain_acl_index"] as? Int, 0)
        XCTAssertEqual(diagnostic.publicValues["continuity_keychain_acl_count"] as? Int, 1024)
        XCTAssertEqual(diagnostic.publicValues["continuity_keychain_acl_application_count"] as? Int, 1024)
    }
}
