import Foundation
import CryptoKit

/// Add-only storage: corruption or an unexpected scope is a blocker, never a
/// reason to rotate a previously enrolled application continuity identity.
protocol SamsungContinuityIdentityStore: AnyObject {
    func read(storageID: String) throws -> Data?
    func insert(_ data: Data, storageID: String) throws
}

struct SamsungContinuityLocalIdentity {
    typealias C = SamsungCloudCertificate
    typealias AddressProvider = () throws -> String
    typealias RandomProvider = () throws -> Data
    private let session: C.Session
    private let installationID: String
    private let address: AddressProvider
    private let store: SamsungContinuityIdentityStore
    private let random: RandomProvider

    init(session: C.Session, installationID: String, address: @escaping AddressProvider,
         store: SamsungContinuityIdentityStore, random: @escaping RandomProvider) throws {
        guard installationID.range(of: "^[a-f0-9]{32}\\z", options: .regularExpression) != nil else { throw C.Failure.missingAccount }
        self.session = session; self.installationID = installationID
        self.address = address; self.store = store; self.random = random
    }

    static func storageID(session: C.Session, installationID: String, address: String, mode: C.IdentityMode) -> String {
        let fields = [session.storageID, installationID, address.uppercased(), mode.rawValue]
        let framed = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(framed.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private struct Record: Codable, C.Redacted {
        let version: Int
        let scope: String
        let address: String
        let mode: C.IdentityMode
        let applicationIdentity: Data
    }
    /// `create` is true only for the explicit enroll_continuity action. Loading
    /// prepared peer context never creates or repairs an identity.
    func load(create: Bool) throws -> C.LocalIdentity {
        let ownAddress = try address().uppercased()
        guard C.validAddress(ownAddress), let first = UInt8(ownAddress.prefix(2), radix: 16), first & 1 == 0 else {
            throw C.Failure.missingBluetoothIdentity
        }
        let scope = Self.storageID(session: session, installationID: installationID,
                                   address: ownAddress, mode: .outgoingClassicApplication)
        func validate(_ bytes: Data) throws -> C.LocalIdentity {
            guard bytes.count <= 4096, let record = try? JSONDecoder().decode(Record.self, from: bytes),
                  record.version == 1, record.scope == scope, record.address == ownAddress,
                  record.mode == .outgoingClassicApplication else { throw C.Failure.continuityIdentityMismatch }
            return try C.LocalIdentity.outgoingClassicApplication(ownClassicAddress: ownAddress,
                                                                 applicationIdentity: record.applicationIdentity)
        }
        if let existing = try store.read(storageID: scope) { return try validate(existing) }
        guard create else { throw C.Failure.continuityIdentityUnavailable }
        let key = try random()
        _ = try C.LocalIdentity.outgoingClassicApplication(ownClassicAddress: ownAddress, applicationIdentity: key)
        let record = Record(version: 1, scope: scope, address: ownAddress,
                            mode: .outgoingClassicApplication, applicationIdentity: key)
        let encoded = try JSONEncoder().encode(record)
        try store.insert(encoded, storageID: scope)
        guard let saved = try store.read(storageID: scope), saved == encoded else { throw C.Failure.continuityIdentityMismatch }
        return try validate(saved)
    }
}
