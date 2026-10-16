import Foundation
import Security

/// Injected in offline tests. The runtime implementation is the only code that
/// touches Keychain. There is intentionally no reset/delete/export-private API.
protocol SamsungCloudCertificateVault: AnyObject {
    func publicKey() throws -> Data?
    func createCSR(deviceID: String) throws -> Data
    func readMaterial() throws -> Data?
    func saveMaterial(_ data: Data) throws
}

final class SamsungCloudCertificateKeychain: SamsungCloudCertificateVault {
    private let storageID: String
    private let backend: SamsungContinuityKeychainBackend
    private var service: String { backend.service("io.github.galaxybudsclient.certificate-v1.KC01") }
    init(session: SamsungCloudCertificate.Session, backend: SamsungContinuityKeychainBackend = .init()) {
        storageID = session.storageID; self.backend = backend
    }
    private var legacyTag: Data { Data((service + ".rsa." + storageID).utf8) }
    private var tag: Data {
        backend.selection.kind == .file
            ? Data((service + ".rsa.nonextractable.v2." + storageID).utf8) : legacyTag
    }
    private enum StagedLegacyFailure: Error { case exportable }

    private func keyQuery(tag requestedTag: Data? = nil) throws -> [String: Any] {
        // Query the namespace before applying type/class policy. A wrong-type
        // collision must block instead of looking absent and creating a shadow.
        try backend.query([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: requestedTag ?? tag])
    }
    private func materialQuery() throws -> [String: Any] {
        try backend.query([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: storageID])
    }
    private func privateKey(tag requestedTag: Data? = nil) throws -> SecKey? {
        guard let item = try backend.item(keyQuery(tag: requestedTag), purpose: .privateRSA) else { return nil }
        guard CFGetTypeID(item.reference) == SecKeyGetTypeID() else { throw backend.fail(.keyValidate, errSecDecode) }
        let key = item.reference as! SecKey
        // SecItem.h defines extractability for macOS keychain keys. Inspect the
        // persisted item's attributes: SecKeyCopyAttributes' documented minimum
        // set does not include extractability. Never export to test this flag.
        guard let reported = SecKeyCopyAttributes(key) as? [String: Any] else {
            _ = backend.fail(.keyValidate, errSecAuthFailed)
            throw SamsungCloudCertificate.Failure.privateKeyUnavailable
        }
        let attributes = reported.merging(item.attributes) { _, persisted in persisted }
        guard reported[kSecAttrIsExtractable as String] == nil || reported[kSecAttrIsExtractable as String] as? Bool == false,
              SamsungContinuityKeychainBackend.keyIsPrivateNonextractableRSA2048(attributes) else {
            _ = backend.fail(.keyValidate, errSecAuthFailed, key: .init(attributes: attributes, reported: reported))
            // Only our legacy file tag, already validated creator ACL, RSA/private
            // class and size, with positively reported exportability (the persisted flag may be absent), can be
            // retired during the explicit GET204/no-material CSR branch below.
            if backend.selection.kind == .file, requestedTag == legacyTag,
               SamsungContinuityKeychainBackend.keyIsPrivateRSA(attributes),
               attributes[kSecAttrKeySizeInBits as String] as? Int == 2048,
               attributes[kSecAttrIsExtractable as String] as? Bool == true,
               reported[kSecAttrIsExtractable as String] as? Bool == true {
                throw StagedLegacyFailure.exportable
            }
            throw SamsungCloudCertificate.Failure.privateKeyUnavailable
        }
        return key
    }
    private func preferredPrivateKey() throws -> SecKey? {
        if let current = try privateKey() { return current }
        return backend.selection.kind == .file ? try privateKey(tag: legacyTag) : nil
    }
    func publicKey() throws -> Data? {
        let loaded: SecKey?
        do { loaded = try preferredPrivateKey() }
        catch is StagedLegacyFailure { throw SamsungCloudCertificate.Failure.privateKeyUnavailable }
        guard let key = loaded else { return nil }
        guard let publicKey = SecKeyCopyPublicKey(key),
              let data = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            _ = backend.fail(.keyValidate, errSecInvalidKeyRef)
            throw SamsungCloudCertificate.Failure.privateKeyUnavailable
        }
        return data
    }
    func createCSR(deviceID: String) throws -> Data {
        let key: SecKey
        let staged: SecKey?
        do { staged = try preferredPrivateKey() }
        catch is StagedLegacyFailure {
            // Lifecycle calls this only after explicit enrollment + HTTP204.
            // Never replace a registered certificate or any local material.
            guard try readMaterial() == nil else { throw SamsungCloudCertificate.Failure.invalidCertificate }
            // Keep the old private key intact. New v2 storage is add-only and
            // its top-level nonextractability is verified before any CSR POST.
            staged = nil
        }
        if let existing = staged { key = existing }
        else {
            var privateAttributes = try backend.creationProtection()
            privateAttributes[kSecAttrIsPermanent as String] = true
            privateAttributes[kSecAttrApplicationTag as String] = tag
            privateAttributes[kSecAttrIsExtractable as String] = false
            var attributes = try backend.query([
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048])
            // Query-only nonsynchronizable/access-group attributes belong in the
            // private-key attributes for generation, not the outer keypair.
            attributes.removeValue(forKey: kSecAttrSynchronizable as String)
            attributes.removeValue(forKey: kSecAttrAccessGroup as String)
            attributes = SamsungContinuityKeychainBackend.rsaGenerationAttributes(
                base: attributes, privateAttributes: privateAttributes, purpose: backend.selection.kind)
            var error: Unmanaged<CFError>?
            guard let generated = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                let status = error.flatMap { OSStatus(exactly: CFErrorGetCode($0.takeRetainedValue())) } ?? errSecInternalComponent
                // Only a documented duplicate permits a read of a concurrent
                // winner. Other errors never trigger a different backend.
                if status == errSecDuplicateItem, let existing = try privateKey() {
                    return try SamsungCloudCertificateDER.csr(deviceID: deviceID, privateKey: existing)
                }
                throw backend.fail(.keyCreate, status)
            }
            guard let persisted = try privateKey(), let expected = SecKeyCopyPublicKey(generated),
                  let actual = SecKeyCopyPublicKey(persisted),
                  let expectedData = SecKeyCopyExternalRepresentation(expected, nil) as Data?,
                  let actualData = SecKeyCopyExternalRepresentation(actual, nil) as Data?, expectedData == actualData else {
                throw backend.fail(.keyReadback, errSecAuthFailed)
            }
            key = persisted
        }
        return try SamsungCloudCertificateDER.csr(deviceID: deviceID, privateKey: key)
    }
    func readMaterial() throws -> Data? {
        guard let item = try backend.item(materialQuery()) else { return nil }
        return try backend.data(item)
    }
    func saveMaterial(_ data: Data) throws {
        // One atomic item holds validated material. Validate existing protection
        // before updating that exact persistent ref; never replace its ACL.
        let query = try materialQuery()
        if let existing = try backend.item(query) {
            try backend.check(SecItemUpdate(try backend.exactQuery(existing) as CFDictionary,
                [kSecValueData as String: data] as CFDictionary), .update)
        } else {
            var item = query.merging(try backend.creationProtection()) { _, new in new }
            item[kSecValueData as String] = data
            // A concurrent add is a blocker, never an overwrite of its winner.
            try backend.check(SecItemAdd(item as CFDictionary, nil), .add)
        }
    }
}
