import XCTest
@testable import BudsAutoSwitch

final class SamsungMdeAccountEchoTests: XCTestCase {
    func testAndroidMetadataRequestIsDistinctFromWindowsPhoneClassVariant() throws {
        let android = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(SamsungMdePacket.requestAndroidMetadataSwitch()))
        let windows = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(SamsungMdePacket.requestMobileCompatibilitySwitch()))
        XCTAssertEqual(android.command, 0x71)
        XCTAssertTrue(android.payload.isEmpty)
        XCTAssertFalse(android.isFragment)
        XCTAssertFalse(android.isResponse)
        XCTAssertEqual(windows.payload, Data([2]))
        XCTAssertNotEqual(SamsungMdePacket.requestAndroidMetadataSwitch(), SamsungMdePacket.requestMobileCompatibilitySwitch())
    }
    func testAndroidVersion2PreservesOnlyOwnedConfigurationAndReportsClosedEchoStates() throws {
        let version3 = try SamsungMdePacket.configureOwnedAccountVersion3(accountFingerprint: Data(0...31))
        let version2 = try SamsungMdePacket.version2OwnedConfiguration(from: version3)
        let decoded = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(version2))
        XCTAssertEqual(Array(decoded.payload), [4, 3, 7, 0, 0, 11, 2, 1, 0x63, 0x0d])
        XCTAssertThrowsError(try SamsungMdePacket.version2OwnedConfiguration(from: SamsungMdePacket.configureVersion3()))
        XCTAssertEqual(SamsungMdePacket.accountTagEchoStatus(status(hash: [0x63, 0x0d]), ownedConfiguration: version2), .matching)
        XCTAssertEqual(SamsungMdePacket.accountTagEchoStatus(status(hash: [0, 0]), ownedConfiguration: version2), .zero)
        XCTAssertEqual(SamsungMdePacket.accountTagEchoStatus(status(hash: [0x0d, 0x63]), ownedConfiguration: version2), .byteReversed)
        XCTAssertEqual(SamsungMdePacket.accountTagEchoStatus(status(hash: [1, 2]), ownedConfiguration: version2), .different)
    }
    private func status(hash: [UInt8], read: Bool = false, fragmented: Bool = false) -> SamsungMdePacket.Frame {
        let value: [UInt8] = [11, 0, 129, 3, 2] + hash + [1]
        return .init(command: read ? 0x44 : 0x45, payload: Data((read ? [0, 2] : []) + [2, 5, 8] + value),
            sequence: 0, isResponse: read, isFragment: fragmented)
    }
    func testOwnedTagEchoIsEqualityWithoutPublishingTagOrClaimingAuthentication() throws {
        let config = try SamsungMdePacket.configureOwnedAccountVersion3(accountFingerprint: Data(0...31))
        XCTAssertEqual(SamsungMdePacket.accountTagMatches(status(hash: [0x63, 0x0d]), ownedConfiguration: config), true)
        XCTAssertEqual(SamsungMdePacket.accountTagMatches(status(hash: [0x63, 0x0d], read: true), ownedConfiguration: config), true)
        XCTAssertEqual(SamsungMdePacket.accountTagMatches(status(hash: [0, 0]), ownedConfiguration: config), false)
        XCTAssertNil(SamsungMdePacket.accountTagMatches(status(hash: [0x63, 0x0d], fragmented: true), ownedConfiguration: config))
        XCTAssertNil(SamsungMdePacket.accountTagMatches(status(hash: [0, 0]), ownedConfiguration: SamsungMdePacket.configureVersion3()))
    }
    func testMobileCompatibilityChangesOnlyRecoveredClassFields() throws {
        let pc = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(SamsungMdePacket.settingInfoClassicBluetooth()))
        let mobile = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(SamsungMdePacket.settingInfoMobileCompatibilityBluetooth()))
        XCTAssertEqual(pc.command, mobile.command); XCTAssertEqual(mobile.command, 0x73)
        var expected = Array(pc.payload); expected[1] = 2
        XCTAssertEqual(Array(mobile.payload), expected)
        let request = try XCTUnwrap(SamsungMdePacket.decodeCompleteFrame(SamsungMdePacket.requestMobileCompatibilitySwitch()))
        XCTAssertEqual(request.command, 0x71); XCTAssertEqual(request.payload, Data([2]))
    }
}
