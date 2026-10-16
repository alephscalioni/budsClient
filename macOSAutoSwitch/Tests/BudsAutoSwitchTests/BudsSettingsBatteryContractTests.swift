import XCTest
@testable import BudsAutoSwitch

final class BudsSettingsBatteryContractTests: XCTestCase {
    private let address = "AA:BB:CC:DD:EE:FF"
    private func sample(left: Int? = 0, observed: TimeInterval = 1_000) -> BudsBatterySnapshot {
        .init(address: address, name: "Galaxy Buds3 Pro", model: "Buds3Pro", icon: nil,
            left: left, right: nil, casePercent: 53, observedAt: observed)
    }

    func testStalePresentationCachePreservesDateButNeverChangesOperationalFreshness() throws {
        let data = try JSONEncoder().encode(sample())
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertNil(BudsBatterySnapshot.decode(data, address: address, now: now))
        let cached = try XCTUnwrap(BudsBatterySnapshot.decode(data, address: address, now: now, maximumAge: nil))
        XCTAssertEqual(cached.observedAt, 1_000)
        XCTAssertEqual(cached.panelFields["left"] as? Int, 0)
        XCTAssertTrue(cached.panelFields["right"] is NSNull)
        let date = try XCTUnwrap(cached.panelFields["observed_at"] as? String)
        XCTAssertEqual(ISO8601DateFormatter().date(from: date)?.timeIntervalSince1970, 1_000)
        XCTAssertNil(BudsBatterySnapshot.decode(data, address: "11:22:33:44:55:66", now: now, maximumAge: nil))
        XCTAssertFalse(cached.isFor(address: "11:22:33:44:55:66", now: now))
    }

    func testBatteryFieldsDoNotExposePeerIDsAndRejectInvalidPercentagesAndFutureDate() throws {
        let fields = sample().panelFields
        XCTAssertEqual(Set(fields.keys), Set(["left", "right", "case", "observed_at"]))
        let serialized = try JSONSerialization.data(withJSONObject: fields)
        let text = try XCTUnwrap(String(data: serialized, encoding: .utf8))
        XCTAssertFalse(text.contains(address)); XCTAssertFalse(text.contains("Galaxy")); XCTAssertFalse(text.contains("model"))
        XCTAssertTrue(sample(left: -1).panelFields["left"] is NSNull)
        XCTAssertTrue(sample(left: 101).panelFields["left"] is NSNull)
        for percent in [-1, 101, 255] {
            let data = try JSONEncoder().encode(sample(left: percent))
            XCTAssertNil(BudsBatterySnapshot.decode(data, address: address, now: Date(timeIntervalSince1970: 1_001), maximumAge: nil))
        }
        XCTAssertFalse(sample(observed: .infinity).isFor(address: address))
        XCTAssertFalse(sample(observed: 2_000).isFor(address: address, now: Date(timeIntervalSince1970: 1_000)))
    }
}
