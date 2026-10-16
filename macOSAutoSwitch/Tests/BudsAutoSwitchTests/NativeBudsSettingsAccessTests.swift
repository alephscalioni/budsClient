import XCTest
@testable import BudsAutoSwitch

final class NativeBudsSettingsAccessTests: XCTestCase {
    @MainActor func testAccessoryToolsDoNotRequireDefaultBudsAudioOrCreateOwnership() async {
        let h = NativeControllerHarness(); h.output = 1
        let model = NativeAutoSwitchModel(environment: h.environment()); await model.refresh()
        XCTAssertTrue(model.canUseSettingsTools)
        XCTAssertFalse(model.hasExistingMacSettingsRoute)
        XCTAssertFalse(model.canSetVolume); XCTAssertFalse(model.canManageSettings)
        for _ in 0..<20 { XCTAssertTrue(model.canUseSettingsTools) }
        XCTAssertEqual(h.opens, 0); XCTAssertTrue(h.routeWrites.isEmpty); XCTAssertTrue(h.commands.isEmpty)
    }
    @MainActor func testAcquiredBudsVolumeRemainsAvailableWhileAnotherOutputIsProtected() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        var protectedOutput: UInt32 = 1
        var environment = h.environment()
        environment.armedDevice = { h.armed ? protectedOutput : nil }
        let model = NativeAutoSwitchModel(environment: environment)
        await model.refresh(); model.start(transportGranted: true); await h.settle()
        await h.acquire(model)
        XCTAssertTrue(h.armed)
        XCTAssertTrue(model.canManageSettings)
        let routes = h.routeWrites, commands = h.commands, pauses = h.pauses
        XCTAssertTrue(model.canSetVolume, "Protecting the speakers must not disable the acquired Buds volume")
        protectedOutput = 2
        XCTAssertFalse(model.canSetVolume, "The protected endpoint itself must remain untouched")
        protectedOutput = 1
        h.verifyError = "guard changed"
        XCTAssertFalse(model.canSetVolume)
        h.verifyError = nil
        h.output = 3
        XCTAssertFalse(model.canSetVolume, "A manual output change must not authorize a volume write")
        h.output = 2
        XCTAssertTrue(model.canSetVolume)
        XCTAssertEqual(h.routeWrites, routes); XCTAssertEqual(h.commands, commands); XCTAssertEqual(h.pauses, pauses)
        h.notify(.foreground, stream: .hfp); await h.settle()
        XCTAssertFalse(model.canSetVolume)
        XCTAssertFalse(model.canUseSettingsTools)
        await h.stop(model)
    }

    @MainActor func testGuardedExistingBudsRouteNeedsActualForegroundAndDoesNotCreateAudioOwnership() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        let model = await h.start()
        h.play(); await h.advance(0.2)
        h.playing = false; await h.advance(0.2)
        h.output = 2; h.notify(.foreground); await h.settle()
        XCTAssertTrue(h.armed); XCTAssertTrue(h.open)
        XCTAssertFalse(model.canManageSettings)
        XCTAssertTrue(model.hasExistingMacSettingsRoute)
        let routes = h.routeWrites, commands = h.commands
        for _ in 0..<20 { XCTAssertTrue(model.hasExistingMacSettingsRoute) }
        XCTAssertEqual(h.routeWrites, routes); XCTAssertEqual(h.commands, commands)
        h.notify(.background, stream: []); await h.settle()
        XCTAssertFalse(model.hasExistingMacSettingsRoute)
        h.notify(.foreground, stream: .hfp); await h.settle()
        XCTAssertFalse(model.hasExistingMacSettingsRoute)
        await h.stop(model)
    }
    @MainActor func testExistingBudsRouteIsPassiveAndDoesNotGrantVolumeOrOwnership() async {
        let h = NativeControllerHarness(); h.output = 2
        let model = NativeAutoSwitchModel(environment: h.environment())
        await model.refresh()
        XCTAssertTrue(model.hasExistingMacSettingsRoute)
        XCTAssertFalse(model.canManageSettings); XCTAssertFalse(model.canSetVolume)
        XCTAssertEqual(h.opens, 0); XCTAssertTrue(h.routeWrites.isEmpty); XCTAssertTrue(h.commands.isEmpty)
        h.output = 1
        XCTAssertFalse(model.hasExistingMacSettingsRoute)
        h.output = 2; h.armed = true
        XCTAssertFalse(model.hasExistingMacSettingsRoute)
        h.armed = false
    }

    @MainActor func testPlaybackAlreadyOnBudsCanReadSettingsWithoutCreatingAPlayIntent() async {
        let h = NativeControllerHarness(); h.physicalReleasePolicy = true
        h.output = 2; h.playing = true
        let model = await h.start()
        XCTAssertTrue(model.hasExistingMacSettingsRoute)
        XCTAssertFalse(model.canManageSettings); XCTAssertFalse(model.canSetVolume)
        XCTAssertEqual(h.opens, 0); XCTAssertTrue(h.routeWrites.isEmpty); XCTAssertTrue(h.commands.isEmpty)
        h.playing = false; await h.stop(model)
    }

    @MainActor func testAcquisitionPreparationDoesNotGrantStandaloneSettingsAccess() async {
        let h = NativeControllerHarness(); h.output = 2; h.holdLink = true
        let model = NativeAutoSwitchModel(environment: h.environment())
        await model.refresh(); model.start(transportGranted: true); await h.settle()
        XCTAssertTrue(model.busy)
        XCTAssertFalse(model.hasExistingMacSettingsRoute)
        XCTAssertFalse(model.canUseSettingsTools)
        h.linkGate?.resume(); h.linkGate = nil; await h.settle(); await h.stop(model)
    }
}
