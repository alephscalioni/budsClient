import XCTest
@testable import BudsAutoSwitch

final class BudsBatterySnapshotTests: XCTestCase {
    private let address = "AA:BB:CC:DD:EE:FF"
    private func sample(_ left: Int? = 82, observed: Double = 1000, icon: String = "Buds3ProSilver") -> BudsBatterySnapshot {
        .init(address: address, name: "Galaxy Buds3 Pro", model: "Buds3Pro", icon: icon,
              left: left, right: 81, casePercent: nil, observedAt: observed)
    }
    func testBatteryNeverComesFromAnotherDeviceOrExpiredSnapshot() throws {
        let data = try JSONEncoder().encode(sample())
        XCTAssertNotNil(BudsBatterySnapshot.decode(data, address: "aa-bb-cc-dd-ee-ff", now: Date(timeIntervalSince1970: 1001)))
        XCTAssertNil(BudsBatterySnapshot.decode(data, address: "11:22:33:44:55:66", now: Date(timeIntervalSince1970: 1001)))
        XCTAssertNil(BudsBatterySnapshot.decode(data, address: address, now: Date(timeIntervalSince1970: 1400)))
        XCTAssertNil(BudsBatterySnapshot.decode(data, address: address, now: Date(timeIntervalSince1970: 900)))
    }
    func testBatteryRejectsInvalidPercentAndAssetPathTraversal() throws {
        let data = try JSONEncoder().encode(sample(101))
        XCTAssertNil(BudsBatterySnapshot.decode(data, address: address, now: Date(timeIntervalSince1970: 1001)))
        XCTAssertNil(sample(icon: "../../untrusted").iconPrefix)
        XCTAssertEqual(sample().iconPrefix, "Buds3ProSilver")
    }
    func testInMemoryHUDReadingUsesTheSameExpiryAsDecodedReadings() {
        let reading = sample(0)
        XCTAssertTrue(reading.isCurrent(address: address, now: Date(timeIntervalSince1970: 1_300)))
        XCTAssertFalse(reading.isCurrent(address: address, now: Date(timeIntervalSince1970: 1_301)))
        XCTAssertFalse(reading.isCurrent(address: "11:22:33:44:55:66", now: Date(timeIntervalSince1970: 1_001)))
        XCTAssertFalse(reading.isCurrent(address: address, now: Date(timeIntervalSince1970: 994)))
        XCTAssertFalse(sample(101).isCurrent(address: address, now: Date(timeIntervalSince1970: 1_001)))
        XCTAssertFalse(sample(observed: .nan).isCurrent(address: address))
        // Historical presentation still preserves its timestamp explicitly.
        XCTAssertTrue(reading.isCurrent(address: address, now: Date(timeIntervalSince1970: 2_000), maximumAge: nil))
    }

    func testHUDChoosesNewestNativeReadingInsteadOfOlderLegacyFileOrPassedValue() {
        let now = Date(timeIntervalSince1970: 1_100)
        let oldFile = sample(90, observed: 1_000)
        let native = sample(37, observed: 1_090)
        let passed = sample(80, observed: 1_050)
        for readings in [[oldFile, native, passed], [native, passed, oldFile]] {
            XCTAssertEqual(BudsBatterySnapshot.newestCurrent(readings, address: address, now: now)?.left, 37)
        }
        // A new native observation arriving while the banner is visible wins.
        XCTAssertEqual(BudsBatterySnapshot.newestCurrent([native, sample(36, observed: 1_100)],
            address: address, now: now)?.left, 36)
    }

    func testHUDRejectsEmptyForeignExpiredAndInvalidReadingsWithoutInventingCharge() {
        let now = Date(timeIntervalSince1970: 1_100)
        let empty = BudsBatterySnapshot(address: address, name: "Buds", model: "Buds3Pro", icon: nil,
            left: nil, right: nil, casePercent: nil, observedAt: 1_100)
        let foreign = BudsBatterySnapshot(address: "11:22:33:44:55:66", name: "Buds", model: "Buds3Pro", icon: nil,
            left: 99, right: 99, casePercent: 99, observedAt: 1_100)
        let invalid: [BudsBatterySnapshot?] = [nil, empty, foreign, sample(observed: 799),
            sample(101, observed: 1_100), sample(observed: 1_106)]
        XCTAssertNil(BudsBatterySnapshot.newestCurrent(invalid, address: address, now: now))
        XCTAssertEqual(BudsBatterySnapshot.newestCurrent(invalid + [sample(0, observed: 1_099)],
            address: address, now: now)?.left, 0)
        XCTAssertNil(BudsBatterySnapshot.newestCurrent([sample()], address: address,
            now: Date(timeIntervalSince1970: 1_301)))
    }
}
