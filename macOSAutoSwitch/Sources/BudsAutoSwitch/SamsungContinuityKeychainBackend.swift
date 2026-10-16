import Foundation
import Security

/// Storage selection is a signing-capability decision, never a response to an
/// item operation failing. The file backend does NOT promise DP accessibility,
/// device-only migration protection, or protection from the user's administrator.
struct SamsungContinuityKeychainBackend {
    enum Kind: String { case dataProtection = "data_protection", file = "file_creator_acl", unavailable }
    struct Selection: Equatable {
        let kind: Kind
        let accessGroup: String?
        let status: OSStatus
    }
    enum Operation: String {
        case signing, selection, query, accessCreate, accessRead, accessValidate
        case read, add, update, keyCreate, keyValidate, keyReadback
    }
    enum ACLPurpose: String { case creation, genericSecret = "generic_secret", privateRSA = "private_rsa" }
    enum ACLReason: String {
        case allowed, aclListMissing = "acl_list_missing", emptyAuthorizations = "empty_authorizations"
        case wildcardSensitiveApps = "wildcard_sensitive_apps", emptySensitiveApps = "empty_sensitive_apps"
        case multipleSensitiveApps = "multiple_sensitive_apps", currentAppMismatch = "current_app_mismatch"
        case invalidAuthorizationList = "invalid_authorization_list"
        case invalidAppList = "invalid_app_list", trustedAppDataMissing = "trusted_app_data_missing"
        case missingOwnedGrant = "missing_owned_grant", missingOwnedSigningGrant = "missing_owned_signing_grant"
        case privateRSAExpected = "private_rsa_expected", accessMissing = "access_missing"
        case dpProtectionMismatch = "dp_protection_mismatch"
    }
    struct ACLDiagnostic: Equatable {
        let reason: ACLReason
        let purpose: ACLPurpose
        var aclCount = 0
        var aclIndex = 0
        var authorizationCount = 0
        var publicCount = 0
        var metadataCount = 0
        var sensitiveCount = 0
        var unknownCount = 0
        var anyCount = 0
        var signCount = 0
        var decryptCount = 0
        var readCount = 0
        var exportCount = 0
        var changeCount = 0
        var applicationCount = 0
        var wildcard = false
        var currentAppMatchEvaluated = false
        var currentAppMatch = false
        var publicValues: [String: Any] {
            var result: [String: Any] = ["continuity_keychain_acl_reason": reason.rawValue,
                "continuity_keychain_acl_purpose": purpose.rawValue,
                "continuity_keychain_acl_wildcard": wildcard,
                "continuity_keychain_acl_current_app_match_evaluated": currentAppMatchEvaluated,
                "continuity_keychain_acl_current_app_match": currentAppMatch]
            let counts = ["count": aclCount, "index": aclIndex, "authorization_count": authorizationCount,
                "public_count": publicCount, "metadata_count": metadataCount, "sensitive_count": sensitiveCount,
                "unknown_count": unknownCount, "any_count": anyCount, "sign_count": signCount,
                "decrypt_count": decryptCount, "read_count": readCount, "export_count": exportCount,
                "change_count": changeCount, "application_count": applicationCount]
            for (key, value) in counts { result["continuity_keychain_acl_" + key] = max(0, min(value, 1024)) }
            return result
        }
    }
    /// Pure assessment of one ACL. Only encryption is admitted as a public RSA
    /// operation; export (including wrapped), read, sign, derive, MAC, ACL/owner
    /// changes, ANY, and unknown authorizations still require the singleton app.
    static func assessACL(_ auth: [String], applications: [Data]?, own: Data,
                          purpose: ACLPurpose, aclCount: Int = 1, aclIndex: Int = 0) -> ACLDiagnostic {
        let metadata = [kSecACLAuthorizationPartitionID as String, kSecACLAuthorizationIntegrity as String]
        let knownSensitive = [kSecACLAuthorizationAny, kSecACLAuthorizationLogin, kSecACLAuthorizationGenKey,
            kSecACLAuthorizationDelete, kSecACLAuthorizationExportWrapped, kSecACLAuthorizationExportClear,
            kSecACLAuthorizationImportWrapped, kSecACLAuthorizationImportClear, kSecACLAuthorizationSign,
            kSecACLAuthorizationDecrypt, kSecACLAuthorizationMAC, kSecACLAuthorizationDerive,
            kSecACLAuthorizationKeychainCreate, kSecACLAuthorizationKeychainDelete,
            kSecACLAuthorizationKeychainItemRead, kSecACLAuthorizationKeychainItemInsert,
            kSecACLAuthorizationKeychainItemModify, kSecACLAuthorizationKeychainItemDelete,
            kSecACLAuthorizationChangeACL, kSecACLAuthorizationChangeOwner].map { $0 as String }
        let publicCount = auth.filter { $0 == kSecACLAuthorizationEncrypt as String }.count
        let metadataCount = auth.filter { metadata.contains($0) }.count
        let sensitiveCount = auth.count - metadataCount - (purpose == .privateRSA ? publicCount : 0)
        var reason: ACLReason = .allowed
        if auth.isEmpty { reason = .emptyAuthorizations }
        // Apple SecAccessCreate defines an empty CHANGE_ACL owner entry:
        // no application is preapproved; the user must authorize changes.
        // This is distinct from a nil list, which trusts every application.
        else if sensitiveCount > 0 && !Self.promptedOwner(auth, applications: applications) {
            if applications == nil { reason = .wildcardSensitiveApps }
            else if applications!.isEmpty { reason = .emptySensitiveApps }
            else if applications!.count != 1 { reason = .multipleSensitiveApps }
            else if !creatorOnly(applications, own: own) { reason = .currentAppMismatch }
        }
        var result = ACLDiagnostic(reason: reason, purpose: purpose)
        result.aclCount = aclCount; result.aclIndex = aclIndex; result.authorizationCount = auth.count
        result.publicCount = publicCount; result.metadataCount = metadataCount; result.sensitiveCount = sensitiveCount
        result.unknownCount = auth.filter { !metadata.contains($0) && $0 != kSecACLAuthorizationEncrypt as String && !knownSensitive.contains($0) }.count
        result.anyCount = auth.filter { $0 == kSecACLAuthorizationAny as String }.count
        result.signCount = auth.filter { $0 == kSecACLAuthorizationSign as String }.count
        result.decryptCount = auth.filter { $0 == kSecACLAuthorizationDecrypt as String }.count
        result.readCount = auth.filter { $0 == kSecACLAuthorizationKeychainItemRead as String }.count
        result.exportCount = auth.filter { $0 == kSecACLAuthorizationExportClear as String || $0 == kSecACLAuthorizationExportWrapped as String }.count
        result.changeCount = auth.filter { $0 == kSecACLAuthorizationChangeACL as String || $0 == kSecACLAuthorizationChangeOwner as String }.count
        result.applicationCount = applications?.count ?? 0; result.wildcard = applications == nil
        result.currentAppMatchEvaluated = applications != nil && !own.isEmpty
        result.currentAppMatch = applications?.contains(own) == true && !own.isEmpty
        return result
    }
    static func promptedOwner(_ authorizations: [String], applications: [Data]?) -> Bool {
        authorizations == [kSecACLAuthorizationChangeACL as String] && applications?.isEmpty == true
    }
    static func finishACLAssessment(_ rows: [ACLDiagnostic], purpose: ACLPurpose, aclCount: Int) -> ACLDiagnostic? {
        if let failed = rows.first(where: { $0.reason != .allowed }) { return failed }
        let owned = rows.filter { $0.sensitiveCount > 0 && $0.applicationCount == 1 && $0.currentAppMatch && !$0.wildcard }
        let reason: ACLReason
        if owned.isEmpty { reason = .missingOwnedGrant }
        else if purpose == .privateRSA && !owned.contains(where: { $0.signCount > 0 || $0.anyCount > 0 }) {
            reason = .missingOwnedSigningGrant
        } else { return nil }
        var result = ACLDiagnostic(reason: reason, purpose: purpose, aclCount: aclCount)
        result.authorizationCount = rows.reduce(0) { $0 + $1.authorizationCount }
        result.sensitiveCount = rows.reduce(0) { $0 + $1.sensitiveCount }
        result.publicCount = rows.reduce(0) { $0 + $1.publicCount }
        result.metadataCount = rows.reduce(0) { $0 + $1.metadataCount }
        return result
    }
    struct KeyDiagnostic: Equatable {
        let rsa, privateClass, size2048, extractableFalse, extractionAttributePresent, contradictoryRuntimeReport: Bool
        var publicValues: [String: Any] {
            ["continuity_keychain_key_rsa": rsa, "continuity_keychain_key_private": privateClass,
             "continuity_keychain_key_size_2048": size2048, "continuity_keychain_key_extractable_false": extractableFalse,
             "continuity_keychain_key_extraction_attribute_present": extractionAttributePresent,
             "continuity_keychain_key_contradictory_runtime_report": contradictoryRuntimeReport]
        }
        init(attributes: [String: Any], reported: [String: Any]) {
            func value(_ key: CFString) -> String? { (attributes[key as String] as? String) ?? (attributes[key as String] as? NSNumber)?.stringValue }
            rsa = value(kSecAttrKeyType) == kSecAttrKeyTypeRSA as String
            privateClass = value(kSecAttrKeyClass) == kSecAttrKeyClassPrivate as String
            size2048 = attributes[kSecAttrKeySizeInBits as String] as? Int == 2048
            extractionAttributePresent = attributes[kSecAttrIsExtractable as String] != nil
            extractableFalse = attributes[kSecAttrIsExtractable as String] as? Bool == false
            contradictoryRuntimeReport = reported[kSecAttrIsExtractable as String] != nil && reported[kSecAttrIsExtractable as String] as? Bool != false
        }
    }
    struct Diagnostic: Equatable {
        let backend: Kind
        let operation: Operation
        let status: OSStatus
        var acl: ACLDiagnostic? = nil
        var key: KeyDiagnostic? = nil
        var publicValues: [String: Any] {
            var result: [String: Any] = ["continuity_keychain_backend": backend.rawValue,
                "continuity_keychain_operation": operation.rawValue, "continuity_keychain_osstatus": Int(status)]
            if let acl { result.merge(acl.publicValues) { _, value in value } }
            if let key { result.merge(key.publicValues) { _, value in value } }
            return result
        }
    }
    // Intentionally retains only fixed enums and a numeric status. No errors,
    // identities, access groups, item labels, trusted-app data, or key material.
    private final class Diagnostics {
        let lock = NSLock()
        var value: Diagnostic?
    }
    private static let diagnostics = Diagnostics()
    static var diagnosticSnapshot: Diagnostic? {
        diagnostics.lock.lock(); defer { diagnostics.lock.unlock() }
        return diagnostics.value
    }
    // Defaults may be constructed even by a rejected/injected enrollment call.
    // Defer all signing APIs until an actual store operation needs selection.
    private static let runtimeSelection = actualSelection()
    private let suppliedSelection: Selection?
    var selection: Selection { suppliedSelection ?? Self.runtimeSelection }
    init(selection: Selection) { suppliedSelection = selection }
    init() { suppliedSelection = nil }

    /// Pure policy, also exercised by offline tests. An explicitly malformed or
    /// shared-only entitlement is a blocker, not permission to try another store.
    static func select(entitlements: [String: Any]) -> Selection {
        let ids = ["application-identifier", "com.apple.application-identifier"]
            .compactMap { entitlements[$0] }
        let groups = entitlements["keychain-access-groups"]
        guard !ids.isEmpty || groups != nil else {
            return Selection(kind: .file, accessGroup: nil, status: errSecSuccess)
        }
        guard let appID = ids.first as? String, !appID.isEmpty,
              !appID.contains("*"), !appID.contains(where: { $0.isWhitespace }),
              ids.allSatisfy({ ($0 as? String) == appID }) else {
            return Selection(kind: .unavailable, accessGroup: nil, status: errSecMissingEntitlement)
        }
        if let groups {
            guard let values = groups as? [String], !values.isEmpty,
                  values.allSatisfy({ !$0.isEmpty && !$0.contains("*") }), values.contains(appID) else {
                return Selection(kind: .unavailable, accessGroup: nil, status: errSecMissingEntitlement)
            }
        }
        return Selection(kind: .dataProtection, accessGroup: appID, status: errSecSuccess)
    }

    private static func actualSelection() -> Selection {
        var code: SecCode?
        var status = SecCodeCopySelf([], &code)
        guard status == errSecSuccess, let code else {
            return Selection(kind: .unavailable, accessGroup: nil, status: status == 0 ? errSecInternalComponent : status)
        }
        status = SecCodeCheckValidity(code, [], nil)
        if status == errSecCSUnsigned { return select(entitlements: [:]) }
        guard status == errSecSuccess else { return Selection(kind: .unavailable, accessGroup: nil, status: status) }
        var staticCode: SecStaticCode?
        status = SecCodeCopyStaticCode(code, [], &staticCode)
        guard status == errSecSuccess, let staticCode else {
            return Selection(kind: .unavailable, accessGroup: nil, status: status == 0 ? errSecInternalComponent : status)
        }
        var info: CFDictionary?
        status = SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
        guard status == errSecSuccess, let values = info as? [String: Any] else {
            return Selection(kind: .unavailable, accessGroup: nil, status: status == 0 ? errSecInternalComponent : status)
        }
        if let raw = values[kSecCodeInfoEntitlementsDict as String] {
            guard let entitlements = raw as? [String: Any] else {
                return Selection(kind: .unavailable, accessGroup: nil, status: errSecDecode)
            }
            return select(entitlements: entitlements)
        }
        guard values[kSecCodeInfoEntitlements as String] == nil else {
            return Selection(kind: .unavailable, accessGroup: nil, status: errSecDecode)
        }
        return select(entitlements: [:])
    }

    func fail(_ operation: Operation, _ status: OSStatus, acl: ACLDiagnostic? = nil, key: KeyDiagnostic? = nil) -> SamsungCloudCertificate.Failure {
        Self.diagnostics.lock.lock()
        Self.diagnostics.value = Diagnostic(backend: selection.kind, operation: operation, status: status, acl: acl, key: key)
        Self.diagnostics.lock.unlock()
        return .keychainUnavailable
    }
    func check(_ status: OSStatus, _ operation: Operation) throws {
        guard status == errSecSuccess else { throw fail(operation, status) }
    }
    func service(_ original: String) -> String {
        selection.kind == .file ? original + ".file-creator-acl.v1" : original
    }
    func query(_ attributes: [String: Any]) throws -> [String: Any] {
        guard selection.kind != .unavailable else { throw fail(.selection, selection.status) }
        guard selection.kind != .dataProtection || selection.accessGroup?.isEmpty == false else {
            throw fail(.selection, errSecMissingEntitlement)
        }
        var result = attributes
        result[kSecUseDataProtectionKeychain as String] = selection.kind == .dataProtection
        if selection.kind == .dataProtection {
            result[kSecAttrSynchronizable as String] = false
            result[kSecAttrAccessGroup as String] = selection.accessGroup
        } else {
            for key in [kSecAttrSynchronizable, kSecAttrAccessible, kSecAttrAccessControl, kSecAttrAccessGroup] {
                result.removeValue(forKey: key as String)
            }
        }
        return result
    }
    func creationProtection() throws -> [String: Any] {
        guard selection.kind != .unavailable else { throw fail(.selection, selection.status) }
        if selection.kind == .dataProtection {
            guard let group = selection.accessGroup, !group.isEmpty else {
                throw fail(.selection, errSecMissingEntitlement)
            }
            return [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    kSecAttrSynchronizable as String: false,
                    kSecAttrAccessGroup as String: group]
        }
        var access: SecAccess?
        // Apple: nil trustedlist means the creating application only. [] does
        // not mean the creator, and nil ACL application lists mean wildcard.
        try check(SecAccessCreate("Buds continuity" as CFString, nil, &access), .accessCreate)
        guard let access else { throw fail(.accessCreate, errSecInternalComponent) }
        var own: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath(nil, &own), .accessCreate)
        guard let own else { throw fail(.accessCreate, errSecInternalComponent) }
        // Normalize newly constructed access only, never an existing item's ACL.
        // Preserve system partition/integrity constraints and prompt selectors.
        for acl in try aclList(access) where !Self.metadataOnly(try authorizations(acl)) {
            var apps: CFArray?, description: CFString?
            var prompt = SecKeychainPromptSelector(rawValue: 0)
            try check(SecACLCopyContents(acl, &apps, &description, &prompt), .accessCreate)
            if try authorizations(acl) == [kSecACLAuthorizationChangeACL as String],
               apps.map({ CFArrayGetCount($0) }) == 0 { continue }
            try check(SecACLSetContents(acl, [own] as CFArray, description ?? "Buds continuity" as CFString, prompt), .accessCreate)
        }
        try validateAccess(access, purpose: .creation)
        return [kSecAttrAccess as String: access]
    }

    /// Partition/integrity ACLs are additional system constraints, not a grant
    /// of decrypt/sign access to arbitrary apps. Never interpret their nil app
    /// list as a wildcard grant, or relax a mixed partition + secret-access ACL.
    static func metadataOnly(_ authorizations: [String]) -> Bool {
        !authorizations.isEmpty && authorizations.allSatisfy {
            $0 == kSecACLAuthorizationPartitionID as String || $0 == kSecACLAuthorizationIntegrity as String
        }
    }
    static func creatorOnly(_ applications: [Data]?, own: Data) -> Bool {
        guard let applications, applications.count == 1, !own.isEmpty else { return false }
        return applications[0] == own
    }
    private func aclList(_ access: SecAccess, purpose: ACLPurpose = .creation) throws -> [SecACL] {
        var list: CFArray?
        try check(SecAccessCopyACLList(access, &list), .accessRead)
        guard let values = list as? [SecACL], !values.isEmpty else { throw fail(.accessValidate, errSecAuthFailed, acl: .init(reason: .aclListMissing, purpose: purpose)) }
        return values
    }
    private func authorizations(_ acl: SecACL, purpose: ACLPurpose = .creation,
                                aclCount: Int = 0, aclIndex: Int = 0) throws -> [String] {
        let raw = SecACLCopyAuthorizations(acl)
        guard let values = raw as? [String] else {
            throw fail(.accessValidate, errSecDecode, acl: .init(reason: .invalidAuthorizationList,
                purpose: purpose, aclCount: aclCount, aclIndex: aclIndex, authorizationCount: CFArrayGetCount(raw)))
        }
        return values
    }
    private func appData(_ app: SecTrustedApplication, purpose: ACLPurpose = .creation) throws -> Data {
        var data: CFData?
        try check(SecTrustedApplicationCopyData(app, &data), .accessRead)
        guard let data, CFDataGetLength(data) > 0 else { throw fail(.accessValidate, errSecAuthFailed, acl: .init(reason: .trustedAppDataMissing, purpose: purpose)) }
        return data as Data
    }
    private func validateAccess(_ access: SecAccess, purpose: ACLPurpose) throws {
        var own: SecTrustedApplication?
        try check(SecTrustedApplicationCreateFromPath(nil, &own), .accessRead)
        guard let own else { throw fail(.accessValidate, errSecAuthFailed,
            acl: .init(reason: .trustedAppDataMissing, purpose: purpose)) }
        let ownData = try appData(own, purpose: purpose)
        let list = try aclList(access, purpose: purpose)
        var assessments: [ACLDiagnostic] = []
        for (index, acl) in list.enumerated() {
            let auth = try authorizations(acl, purpose: purpose, aclCount: list.count, aclIndex: index)
            // Partition/integrity constraints have no application grant. Keep
            // them intact without assuming they have simple application data.
            if Self.metadataOnly(auth) { continue }
            var apps: CFArray?, description: CFString?
            var prompt = SecKeychainPromptSelector(rawValue: 0)
            try check(SecACLCopyContents(acl, &apps, &description, &prompt), .accessRead)
            let trusted = apps as? [SecTrustedApplication]
            if apps != nil && trusted == nil {
                throw fail(.accessValidate, errSecAuthFailed,
                    acl: .init(reason: .invalidAppList, purpose: purpose, aclCount: list.count, aclIndex: index, authorizationCount: auth.count))
            }
            let appBytes = try trusted?.map { try appData($0, purpose: purpose) }
            let assessment = Self.assessACL(auth, applications: appBytes, own: ownData,
                purpose: purpose, aclCount: list.count, aclIndex: index)
            guard assessment.reason == .allowed else { throw fail(.accessValidate, errSecAuthFailed, acl: assessment) }
            assessments.append(assessment)
        }
        if let failure = Self.finishACLAssessment(assessments, purpose: purpose, aclCount: list.count) {
            throw fail(.accessValidate, errSecAuthFailed, acl: failure)
        }
    }
    func validateItem(_ reference: CFTypeRef, attributes: [String: Any], purpose: ACLPurpose) throws {
        if selection.kind == .dataProtection {
            guard attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String,
                  attributes[kSecAttrSynchronizable as String] as? Bool != true,
                  attributes[kSecAttrAccessGroup as String] as? String == selection.accessGroup else {
                throw fail(.accessValidate, errSecAuthFailed, acl: .init(reason: .dpProtectionMismatch, purpose: purpose))
            }
        } else if selection.kind == .file {
            if purpose == .privateRSA {
                guard CFGetTypeID(reference) == SecKeyGetTypeID(),
                      let keyAttributes = SecKeyCopyAttributes(reference as! SecKey) as? [String: Any],
                      Self.keyIsPrivateRSA(keyAttributes) else {
                    throw fail(.accessValidate, errSecAuthFailed, acl: .init(reason: .privateRSAExpected, purpose: purpose))
                }
            }
            var access: SecAccess?
            // Legacy SecKey refs and generic-password refs are Keychain items.
            try check(SecKeychainItemCopyAccess(unsafeBitCast(reference, to: SecKeychainItem.self), &access), .accessRead)
            guard let access else { throw fail(.accessValidate, errSecAuthFailed,
                acl: .init(reason: .accessMissing, purpose: purpose)) }
            try validateAccess(access, purpose: purpose)
        } else { throw fail(.selection, selection.status) }
    }

    struct Item {
        let reference: CFTypeRef
        let persistentReference: Data
        let attributes: [String: Any]
    }
    func item(_ base: [String: Any], purpose: ACLPurpose = .genericSecret) throws -> Item? {
        var request = base
        request[kSecReturnAttributes as String] = true
        request[kSecReturnRef as String] = true
        request[kSecReturnPersistentRef as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, .read)
        guard let matches = result as? [[String: Any]], matches.count == 1,
              let ref = matches[0][kSecValueRef as String],
              let persistent = matches[0][kSecValuePersistentRef as String] as? Data else {
            throw fail(.read, errSecDecode)
        }
        try validateItem(ref as CFTypeRef, attributes: matches[0], purpose: purpose)
        return Item(reference: ref as CFTypeRef, persistentReference: persistent, attributes: matches[0])
    }
    func exactQuery(_ item: Item) throws -> [String: Any] {
        try query([kSecValuePersistentRef as String: item.persistentReference])
    }
    func data(_ item: Item) throws -> Data {
        var request = try exactQuery(item)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        try check(SecItemCopyMatching(request as CFDictionary, &result), .read)
        guard let data = result as? Data else { throw fail(.read, errSecDecode) }
        return data
    }
    static func keyIsPrivateRSA(_ attributes: [String: Any]) -> Bool {
        func value(_ key: CFString) -> String? {
            let raw = attributes[key as String]
            return (raw as? String) ?? (raw as? NSNumber)?.stringValue
        }
        return value(kSecAttrKeyType) == kSecAttrKeyTypeRSA as String &&
            value(kSecAttrKeyClass) == kSecAttrKeyClassPrivate as String
    }
    /// Supply file SecAccess at the whole-keypair top level, retaining the same
    /// object in private attributes. The SDK does not document SecAccess among
    /// its guaranteed per-key overrides. Persisted ACL validation remains required.
    static func rsaGenerationAttributes(base: [String: Any], privateAttributes: [String: Any],
                                        purpose: Kind) -> [String: Any] {
        var result = base
        if purpose == .file {
            result[kSecAttrAccess as String] = privateAttributes[kSecAttrAccess as String]
            // Native macOS runtime verification: nested-only false is ignored
            // by the file backend; the whole-keypair attribute is required.
            result[kSecAttrIsExtractable as String] = false
        }
        result[kSecPrivateKeyAttrs as String] = privateAttributes
        return result
    }
    static func keyIsPrivateNonextractableRSA2048(_ attributes: [String: Any]) -> Bool {
        // Legacy file RSA reports some enum attributes as CFNumber; modern
        // Security refs commonly return the corresponding CFString constants.
        func value(_ key: CFString) -> String? {
            let raw = attributes[key as String]
            return (raw as? String) ?? (raw as? NSNumber)?.stringValue
        }
        return attributes[kSecAttrIsExtractable as String] as? Bool == false &&
        attributes[kSecAttrKeySizeInBits as String] as? Int == 2048 &&
        value(kSecAttrKeyType) == kSecAttrKeyTypeRSA as String &&
        value(kSecAttrKeyClass) == kSecAttrKeyClassPrivate as String
    }
}
