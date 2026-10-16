import Foundation
import Security
import IOBluetooth

/// Runtime providers only. Offline tests inject every provider and never call
/// this implementation. No deletion, update, synchronization or export API.
final class SamsungContinuityLocalIdentityKeychain: SamsungContinuityIdentityStore {
    private let backend: SamsungContinuityKeychainBackend
    init(backend: SamsungContinuityKeychainBackend = .init()) { self.backend = backend }
    private func query(_ storageID: String) throws -> [String: Any] {
        try backend.query([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: backend.service("io.github.galaxybudsclient.continuity.outgoing-classic.v1"),
            kSecAttrAccount as String: storageID])
    }
    func read(storageID: String) throws -> Data? {
        guard let item = try backend.item(query(storageID)) else { return nil }
        return try backend.data(item)
    }
    func insert(_ data: Data, storageID: String) throws {
        var item = try query(storageID).merging(backend.creationProtection()) { _, new in new }
        item[kSecValueData as String] = data
        // Atomic add-only; duplicates and corrupted existing identities are
        // blockers. No update, reset, migration, or repair path exists here.
        try backend.check(SecItemAdd(item as CFDictionary, nil), .add)
    }
    static func ownClassicAddress() throws -> String {
        guard let address = IOBluetoothHostController.default()?.addressAsString() else {
            throw SamsungCloudCertificate.Failure.missingBluetoothIdentity
        }
        return address.replacingOccurrences(of: "-", with: ":").uppercased()
    }
    static func randomIdentity() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SamsungCloudCertificate.Failure.continuityIdentityUnavailable
        }
        return Data(bytes)
    }
}
