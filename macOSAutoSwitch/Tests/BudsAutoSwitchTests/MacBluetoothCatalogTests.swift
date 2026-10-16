import XCTest
@testable import BudsAutoSwitch

final class MacBluetoothCatalogTests: XCTestCase {
    func testCatalogIncludesConnectedAndDisconnectedPairedBudsWithoutInProcessEnumeration() throws {
        let data = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"Buds3 Pro":{"device_address":"aa-bb-cc-dd-ee-ff"}}],"device_not_connected":[{"Buds4":{"device_address":"11:22:33:44:55:66"}},{"Buds3 Pro":{"device_address":"AA:BB:CC:DD:EE:FF"}},{"Nearby Buds":{"device_address":"00:11:22:33:44:55"}},{"Keyboard":{"device_address":"66:55:44:33:22:11"}}]}]}"#.utf8)
        var verified: [String] = []
        let items = try MacAudio.pairedBuds(from: data, isPaired: {
            verified.append($0)
            return $0 != "00:11:22:33:44:55"
        })
        XCTAssertEqual(items.map(\.address), ["AA:BB:CC:DD:EE:FF", "11:22:33:44:55:66"])
        XCTAssertEqual(items.map(\.name), ["Buds3 Pro", "Buds4"])
        XCTAssertEqual(verified, ["AA:BB:CC:DD:EE:FF", "11:22:33:44:55:66", "00:11:22:33:44:55"])
    }

    func testMalformedAndUnknownCatalogCannotBecomeAnEmptySuccessfulRefresh() throws {
        for text in ["{}", "[]", "{\"SPBluetoothDataType\":false}", "not JSON"] {
            XCTAssertThrowsError(try MacAudio.pairedBuds(from: Data(text.utf8), isPaired: { _ in
                XCTFail("Unrecognized catalog must not inspect devices"); return true
            }))
        }
        XCTAssertTrue(try MacAudio.pairedBuds(from: Data(#"{"SPBluetoothDataType":[]}"#.utf8), isPaired: { _ in true }).isEmpty)
        let malformed = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"Buds":{"device_address":"xxAA:BB:CC:DD:EE:FF"}},{"Buds bad":{"device_address":"AA:BB"}}]}]}"#.utf8)
        XCTAssertTrue(try MacAudio.pairedBuds(from: malformed, isPaired: { _ in
            XCTFail("Malformed address must not inspect devices"); return true
        }).isEmpty)
    }

    @MainActor func testCatalogFailurePreservesSelectedDeviceAndExistingList() async {
        let h = NativeControllerHarness()
        var effects = h.environment()
        var fail = false
        effects.pairedBuds = {
            if fail { throw NativeBudsError(message: "catalog-unavailable") }
            return [("AA:BB:CC:DD:EE:FF", "Test Buds")]
        }
        let model = NativeAutoSwitchModel(environment: effects)
        await model.refresh()
        let selected = model.selectedBuds
        fail = true
        await model.refresh()
        XCTAssertEqual(model.selectedBuds, selected)
        XCTAssertEqual(model.buds.map(\.address), [selected])
        XCTAssertEqual(model.error, "catalog-unavailable")
        XCTAssertEqual(h.opens, 0); XCTAssertEqual(h.arms, 0)
    }

    @MainActor func testCatalogReturningAfterSwitchStartCannotReplaceTheActiveSelection() async {
        let h = NativeControllerHarness()
        var effects = h.environment()
        var resume: CheckedContinuation<[(address: String, name: String)], Never>?
        var delay = false
        effects.pairedBuds = {
            if delay { return await withCheckedContinuation { resume = $0 } }
            return [("AA:BB:CC:DD:EE:FF", "Test Buds")]
        }
        let model = NativeAutoSwitchModel(environment: effects)
        await model.refresh()
        delay = true
        let refresh = Task { await model.refresh() }
        for _ in 0..<1000 where resume == nil { await Task.yield() }
        XCTAssertNotNil(resume)
        model.start(transportGranted: true)
        resume?.resume(returning: [("11:22:33:44:55:66", "Other Buds")])
        await refresh.value
        XCTAssertEqual(model.selectedBuds, "AA:BB:CC:DD:EE:FF")
        await h.stop(model)
    }
}
