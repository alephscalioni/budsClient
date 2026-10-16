import XCTest
@testable import BudsAutoSwitch

final class ContinuityMemoryStore: SamsungContinuityIdentityStore {
    var records: [String: Data] = [:]
    var inserts = 0
    var reads = 0
    var corruptReadback = false
    var failInsert = false
    func read(storageID: String) throws -> Data? { reads += 1; return records[storageID] }
    func insert(_ data: Data, storageID: String) throws {
        inserts += 1
        guard !failInsert, records[storageID] == nil else { throw SamsungCloudCertificate.Failure.keychainUnavailable }
        records[storageID] = corruptReadback ? Data([0]) : data
    }
}

final class SamsungContinuityLocalIdentityTests: XCTestCase {
    typealias C = SamsungCloudCertificate
    let installation = String(repeating: "a", count: 32)
    let address = "12:34:56:78:9A:BC"
    func session(_ account: String = "synthetic-account", _ device: String = "synthetic-device") throws -> C.Session {
        try .init(deviceID: device, accountID: account, cloudUserToken: "synthetic-cloud")
    }
    func provider(_ store: ContinuityMemoryStore, address: String = "12:34:56:78:9A:BC",
                  random: @escaping () throws -> Data = { Data(repeating: 0x41, count: 16) }) throws -> SamsungContinuityLocalIdentity {
        try .init(session: session(), installationID: installation, address: { address }, store: store, random: random)
    }
    func testTwoModesPreserveControllerProvenanceAndRequireApplicationKey() throws {
        let controller = try C.LocalIdentity(verifiedLocalBluetoothAddress: address, controllerCoherentIRK: Data(repeating: 0, count: 16))
        XCTAssertEqual(controller.mode, .controllerCoherent); XCTAssertFalse(controller.outgoingOnly)
        let app = try C.LocalIdentity.outgoingClassicApplication(ownClassicAddress: address.lowercased(), applicationIdentity: Data(repeating: 0x41, count: 16))
        XCTAssertEqual(app.mode, .outgoingClassicApplication); XCTAssertTrue(app.outgoingOnly)
        XCTAssertEqual(app.address, address)
        for count in [0,15,17] {
            XCTAssertThrowsError(try C.LocalIdentity.outgoingClassicApplication(ownClassicAddress: address, applicationIdentity: Data(repeating: 1, count: count)))
        }
        XCTAssertThrowsError(try C.LocalIdentity.outgoingClassicApplication(ownClassicAddress: address, applicationIdentity: Data(repeating: 0, count: 16)))
        for text in [String(describing: app), String(reflecting: app), String(reflecting: Mirror(reflecting: app))] {
            XCTAssertFalse(text.contains(address)); XCTAssertFalse(text.contains("QUFB"))
        }
    }
    func testStorageScopesAccountInstallationClassicAddressAndMode() throws {
        let base = try session()
        func id(_ s: C.Session, _ i: String, _ a: String, _ m: C.IdentityMode) -> String {
            SamsungContinuityLocalIdentity.storageID(session: s, installationID: i, address: a, mode: m)
        }
        let ids = try [id(base,installation,address,.outgoingClassicApplication),
            id(session("other"),installation,address,.outgoingClassicApplication),
            id(session("synthetic-account","other"),installation,address,.outgoingClassicApplication),
            id(base,String(repeating:"b",count:32),address,.outgoingClassicApplication),
            id(base,installation,"22:34:56:78:9A:BC",.outgoingClassicApplication),
            id(base,installation,address,.controllerCoherent)]
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(ids[0], id(base,installation,address.lowercased(),.outgoingClassicApplication))
        XCTAssertTrue(ids.allSatisfy { $0.count == 64 && !$0.contains(address) })
    }
    func testAddOnlyPersistenceReadbackAndNoRotation() throws {
        let store = ContinuityMemoryStore(); var draws = 0
        let factory = try provider(store, random: { draws += 1; return Data(repeating: 0x41, count: 16) })
        XCTAssertThrowsError(try factory.load(create: false)); XCTAssertEqual(draws, 0)
        let first = try factory.load(create: true), bytes = store.records
        let second = try factory.load(create: true)
        XCTAssertEqual(first.address, second.address); XCTAssertEqual(store.records, bytes)
        XCTAssertEqual(store.inserts, 1); XCTAssertEqual(draws, 1)
        _ = try factory.load(create: false); XCTAssertEqual(draws, 1)
    }
    func testCorruptOrMismatchedIdentityNeverOverwritesOrDrawsRandom() throws {
        for field in ["corrupt", "scope", "address", "mode", "version", "applicationIdentity"] {
            let store = ContinuityMemoryStore(); let factory = try provider(store)
            _ = try factory.load(create: true)
            let scope = try XCTUnwrap(store.records.keys.first)
            if field == "corrupt" { store.records[scope] = Data([1]) }
            else {
                var record = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.records[scope])) as? [String: Any])
                record[field] = field == "version" ? 2 : "invalid"
                store.records[scope] = try JSONSerialization.data(withJSONObject: record)
            }
            let original = store.records
            let reload = try provider(store, random: { XCTFail("must not rotate"); return Data() })
            XCTAssertThrowsError(try reload.load(create: true))
            XCTAssertEqual(store.records, original); XCTAssertEqual(store.inserts, 1)
        }
    }
    func testInvalidOwnAddressesAndInstallationRejectedBeforeStorageOrRandom() throws {
        for bad in ["", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF", "02:00:00:00:00:00", "11:22:33:44:55:66", "not-an-address", address + "\n"] {
            let store = ContinuityMemoryStore()
            XCTAssertThrowsError(try provider(store, address: bad, random: { XCTFail("invalid address"); return Data() }).load(create: true))
            XCTAssertEqual(store.reads, 0); XCTAssertEqual(store.inserts, 0)
        }
        XCTAssertThrowsError(try SamsungContinuityLocalIdentity(session: session(), installationID: "bad", address: { self.address }, store: ContinuityMemoryStore(), random: { Data() }))
    }
    func testRandomAndPersistenceFailuresCannotReturnIdentity() throws {
        for scenario in 0..<4 {
            let store = ContinuityMemoryStore(); store.failInsert = scenario == 2; store.corruptReadback = scenario == 3
            let factory = try provider(store, random: {
                if scenario == 0 { throw C.Failure.continuityIdentityUnavailable }
                return Data(repeating: 0x41, count: scenario == 1 ? 15 : 16)
            })
            XCTAssertThrowsError(try factory.load(create: true))
            XCTAssertEqual(store.inserts, scenario < 2 ? 0 : 1)
        }
    }
}
