import XCTest
@testable import BudsAutoSwitch

final class NativeOwnedBudsContextIntegrationTests: XCTestCase {
    @MainActor func testForeground132KeepsRealContextAndAccountRefreshAnnouncement() async {
        let h = NativeControllerHarness(); let model = await start(h)
        await h.acquire(model); metadata(h)
        h.notify(.foreground, reason: 132); await h.settle()
        XCTAssertEqual(model.route, "Mac")
        XCTAssertEqual(model.ownedContinuityBudsContext?.encode(), Data([0x33, 0x11, 0xFF, 0x4D]))
        XCTAssertTrue(model.refreshPeerOwnershipAnnouncement())
        h.notify(.background, reason: 132); await h.settle()
        XCTAssertNil(model.ownedContinuityBudsContext)
        XCTAssertFalse(model.refreshPeerOwnershipAnnouncement())
        await h.stop(model)
    }
    @MainActor private func start(_ h: NativeControllerHarness, source: Bool = true,
                                 hook: (() -> Void)? = nil) async -> NativeAutoSwitchModel {
        var env = h.environment()
        if source {
            env.continuityProfiles = { address, session in
                hook?()
                return .init(address: try! NativeSamsungPeerCoordinator.address(address),
                    session: session, observedAt: h.time, hfp: .connected, bis: false)
            }
        }
        let model = NativeAutoSwitchModel(environment: env)
        await model.refresh(); model.start(transportGranted: true); await h.settle()
        return model
    }
    @MainActor private func metadata(_ h: NativeControllerHarness) {
        h.frame?(.init(command: 0x45, payload: Data([6, 2, 1, 2, 7, 2, 1, 2, 31, 2, 1, 1]),
                       sequence: 0, isResponse: false, isFragment: false))
    }
    @MainActor func testRealMetadataIsCollectedWithoutInventingMissingProfiles() async {
        let h = NativeControllerHarness(); let model = await start(h, source: false)
        await h.acquire(model); metadata(h)
        let known = model.transportDiagnostics["owned_buds_context"] as? [String: Bool]
        XCTAssertEqual(known?["wearing_known"], true)
        XCTAssertEqual(known?["spp_capacity_known"], true)
        XCTAssertEqual(known?["profile_source_available"], false)
        XCTAssertNil(model.ownedContinuityBudsContext)
        await h.stop(model)
    }
    @MainActor func testContextCannotAdvertiseAcquisitionAgainAfterOwnershipLoss() async {
        let h = NativeControllerHarness(); let model = await start(h)
        XCTAssertNil(model.ownedContinuityBudsContext)
        await h.acquire(model); metadata(h)
        XCTAssertEqual(model.ownedContinuityBudsContext?.encode(), Data([0x33, 0x11, 0xFF, 0x4D]))
        h.notify(.background); await h.settle()
        XCTAssertNil(model.ownedContinuityBudsContext, "a yield response must withdraw stale foreground")
        await h.stop(model)
        XCTAssertNil(model.ownedContinuityBudsContext)
    }
    @MainActor func testManualRouteInvalidSensorAndNewChannelFencePublishedContext() async {
        let h = NativeControllerHarness(); let model = await start(h)
        await h.acquire(model); metadata(h)
        XCTAssertNotNil(model.ownedContinuityBudsContext)
        h.output = 3; XCTAssertNil(model.ownedContinuityBudsContext)
        h.output = 2
        h.frame?(.init(command: 0x45, payload: Data([6, 2, 1, 0]), sequence: 0, isResponse: false, isFragment: false))
        XCTAssertNil(model.ownedContinuityBudsContext)
        metadata(h); XCTAssertNotNil(model.ownedContinuityBudsContext)
        let old = h.frame
        await h.stop(model)
        model.start(transportGranted: true); await h.settle(); await h.acquire(model)
        old?(.init(command: 0x45, payload: Data([6, 2, 1, 1, 7, 2, 1, 2, 31, 2, 1, 1]),
                   sequence: 0, isResponse: false, isFragment: false))
        XCTAssertNil(model.ownedContinuityBudsContext, "old callbacks cannot repopulate a new control session")
        await h.stop(model)
    }
    @MainActor func testObserverCallbackCannotPublishAfterSynchronousStop() async {
        let h = NativeControllerHarness()
        weak var target: NativeAutoSwitchModel?
        let model = await start(h, hook: { target?.stop() })
        target = model
        await h.acquire(model); metadata(h)
        XCTAssertNil(model.ownedContinuityBudsContext)
        await h.settle(); XCTAssertFalse(model.enabled)
        await h.stop(model)
    }
}
