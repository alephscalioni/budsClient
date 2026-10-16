import XCTest
@testable import BudsAutoSwitch

final class NativeBudsPanelReadingsTests: XCTestCase {
    func testBatteryDisplayDoesNotDependOnSettingPermissionAndKeepsZeroAndPartialReadings() {
        let battery: [String: Any] = ["left": 94, "right": 89, "case": 0]
        XCTAssertEqual(NativeBudsPanelReadings.battery(battery, key: "left", connected: true), 94)
        XCTAssertEqual(NativeBudsPanelReadings.battery(battery, key: "case", connected: true), 0)
        XCTAssertNil(NativeBudsPanelReadings.battery(battery, key: "left", connected: false))
        let invalids: [Any] = [true, 1.5, 101, -1, Double.nan, "95"]
        for invalid in invalids {
            XCTAssertNil(NativeBudsPanelReadings.battery(["left": invalid], key: "left", connected: true))
        }
        XCTAssertNil(NativeBudsPanelReadings.battery(battery, key: "missing", connected: true))
    }
    func testHistoryDisplaysWithoutAuthorizingControlsOrInventingANewTimestamp() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let previous: [String: Any] = ["model_verified": true, "observed_at": 1_000.0,
            "noise_mode": "anc", "equalizer": 0, "settings_may_have_changed": true]
        let device: [String: Any] = ["can_control": false, "last_observation": previous]
        let value = try XCTUnwrap(NativeBudsPanelReadings.settings(device, connected: true, canControl: false, now: now))
        XCTAssertTrue(value.historical); XCTAssertTrue(value.mayHaveChanged)
        XCTAssertEqual(value.date.timeIntervalSince1970, 1_000)
        XCTAssertEqual(value.values["noise_mode"] as? String, "anc")
        XCTAssertNil(NativeBudsPanelReadings.settings(device, connected: false, canControl: false, now: now))
    }
    func testUnverifiedOrMalformedHistoryCannotReplaceCurrentUnknownValues() {
        let invalids: [[String: Any]] = [
            ["model_verified": false, "observed_at": 1_000.0],
            ["model_verified": 1, "observed_at": 1_000.0],
            ["model_verified": true, "observed_at": Double.infinity],
            ["model_verified": true, "observed_at": 2_006.0],
            ["model_verified": true]
        ]
        for previous in invalids {
            XCTAssertNil(NativeBudsPanelReadings.settings(["last_observation": previous], connected: true,
                canControl: false, now: Date(timeIntervalSince1970: 2_000)))
        }
    }
}
