import XCTest
@testable import BudsAutoSwitch

final class NativeAutoSwitchBatteryTests: XCTestCase {
    @MainActor func testPartialBatteryNotificationNeverRedatesUntouchedPercentages() async throws {
        let h = NativeControllerHarness()
        let model = NativeAutoSwitchModel(environment: h.environment())
        await model.refresh(); model.start(transportGranted: true); await h.settle()
        h.frame?(.init(command: 0x45, payload: Data([8, 2, 1, 37, 9, 2, 1, 32, 10, 2, 1, 50]),
            sequence: 0, isResponse: false, isFragment: false))
        XCTAssertEqual(model.batterySnapshot?.left, 37)
        XCTAssertEqual(model.batterySnapshot?.right, 32)
        XCTAssertEqual(model.batterySnapshot?.casePercent, 50)
        h.frame?(.init(command: 0x45, payload: Data([8, 2, 1, 36]),
            sequence: 0, isResponse: false, isFragment: false))
        XCTAssertEqual(model.batterySnapshot?.left, 36)
        XCTAssertNil(model.batterySnapshot?.right, "A left-only update cannot renew an old right reading")
        XCTAssertNil(model.batterySnapshot?.casePercent, "Case availability is not inferred from an earbud update")
        XCTAssertNotNil(BudsBatterySnapshot.newestCurrent([model.batterySnapshot], address: model.selectedBuds))
        await h.stop(model)
    }
}
