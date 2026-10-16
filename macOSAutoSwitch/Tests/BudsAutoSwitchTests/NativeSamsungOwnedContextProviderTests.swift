import XCTest
import CryptoKit
@testable import BudsAutoSwitch

extension SamsungCloudCertificateTests {
    @MainActor func testOwnedProviderIncludesCurrentEntryAndWithdrawsItOnNextSend() throws {
        let domain = "BudsOwnedContextFixture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let material = try coordinatorMaterial()
        let entry = SamsungContinuityBudsContext(address: try .init(bytes: Data([2, 19, 36, 53, 70, 87])),
            hfp: .connected, a2dp: true, foreground: true, bis: false, wearing: false, sppConnectable: true)
        let published = try NativeSamsungOwnedContextProvider.make(material: material, defaults: defaults, now: now, buds: entry)
        let withdrawn = try NativeSamsungOwnedContextProvider.make(material: material, defaults: defaults, now: now, buds: nil)
        let table = Array(SHA256.hash(data: try XCTUnwrap(material.accountFingerprint).bytes))
        func clear(_ wire: Data) -> [UInt8] {
            let seed = Int(wire[4..<9].reduce(UInt8(0), ^)) % table.count
            var bytes = Array(wire)
            for i in 9..<bytes.count { bytes[i] ^= table[(seed + i) % table.count] }
            return bytes
        }
        XCTAssertEqual(published.count, 22); XCTAssertEqual(withdrawn.count, 18)
        XCTAssertEqual(Array(clear(published)[14..<18]), [0x33, 0x11, 0x57, 0x4D])
        XCTAssertEqual(Array(clear(withdrawn)[14..<18]), [0x34, 2, 0x78, 0x9A])
    }
    @MainActor func testOwnedProviderUsesOwnAddressAndPersistsSequenceWithoutChangingMaterial() throws {
        let domain = "BudsOwnedContextFixture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let material = try coordinatorMaterial()
        let first = try NativeSamsungOwnedContextProvider.make(material: material, defaults: defaults, now: now)
        XCTAssertEqual(first[2], 0x42); XCTAssertEqual(first.count, 18)
        XCTAssertEqual(defaults.integer(forKey: NativeSamsungOwnedContextProvider.sequenceKey), 1)
        _ = try NativeSamsungOwnedContextProvider.make(material: material, defaults: defaults, now: now)
        XCTAssertEqual(defaults.integer(forKey: NativeSamsungOwnedContextProvider.sequenceKey), 2)
        defaults.set(62, forKey: NativeSamsungOwnedContextProvider.sequenceKey)
        _ = try NativeSamsungOwnedContextProvider.make(material: material, defaults: defaults, now: now)
        XCTAssertEqual(defaults.integer(forKey: NativeSamsungOwnedContextProvider.sequenceKey), 1)
        XCTAssertEqual(material.ownClassicAddress, "12:34:56:78:9A:BC")
        XCTAssertEqual(material.identityMode, .outgoingClassicApplication)
        // Independently undo the artifact's XOR transformation to inspect the
        // exact owned identity bytes and conservative service capabilities.
        let table = Array(SHA256.hash(data: try XCTUnwrap(material.accountFingerprint).bytes))
        let seed = Int(first[4..<9].reduce(UInt8(0), ^)) % table.count
        var decoded = Array(first)
        for i in 9..<decoded.count { decoded[i] ^= table[(seed + i) % table.count] }
        XCTAssertEqual(decoded[2] & 15, 2)
        XCTAssertEqual(Array(decoded[9..<14]), [0, 0, 0, 0, 0])
        XCTAssertEqual(Array(decoded[14..<18]), [0x34, 1, 0x78, 0x9a])
    }

    @MainActor func testOwnedProviderInvalidSequenceAndClockNeverResetThePersistedLease() throws {
        let domain = "BudsOwnedContextFixture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let material = try coordinatorMaterial()
        for value in [63, -1, 1_000_000] {
            defaults.set(value, forKey: NativeSamsungOwnedContextProvider.sequenceKey)
            XCTAssertThrowsError(try NativeSamsungOwnedContextProvider.make(material: material, defaults: defaults, now: now))
            XCTAssertEqual(defaults.integer(forKey: NativeSamsungOwnedContextProvider.sequenceKey), value)
        }
        defaults.set(11, forKey: NativeSamsungOwnedContextProvider.sequenceKey)
        XCTAssertThrowsError(try NativeSamsungOwnedContextProvider.make(material: material, defaults: defaults,
            now: Date(timeIntervalSince1970: -1)))
        XCTAssertEqual(defaults.integer(forKey: NativeSamsungOwnedContextProvider.sequenceKey), 11)
    }
}
