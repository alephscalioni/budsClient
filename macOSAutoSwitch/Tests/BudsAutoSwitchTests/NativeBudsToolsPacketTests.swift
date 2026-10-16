import XCTest
@testable import BudsAutoSwitch

final class NativeBudsToolsPacketTests: XCTestCase {
    typealias P = SamsungBudsSettingsPacket
    private func f(_ command: UInt8, _ payload: [UInt8] = []) -> P.Frame { .init(command: command, payload: Data(payload), isFragment: false) }
    func testClosedToolWhitelistAndHelperWireNeverAdmitFirmwareResetOrAlternateStart() {
        for frame in [f(0x9D, [0]), f(0x9D, [1]), f(0xA6), f(0xA1), f(0xA2, [0, 1]), f(0xA2, [1, 0])] {
            XCTAssertTrue(NativeBudsToolsPacket.permits(frame))
            XCTAssertTrue(NativeBudsSettingsWire.permittedWrite(P.frame(command: frame.command, payload: Array(frame.payload))))
        }
        for frame in [f(0xA0), f(0xA6, [0]), f(0xA1, [0]), f(0x9D), f(0x9D, [2]), f(0xA2, [2, 1]), f(0xA2, [0]), f(0xA3, [0, 0]), f(0x9E, [1, 1]), f(0x50), f(0xAF, [0])] {
            XCTAssertFalse(NativeBudsToolsPacket.permits(frame))
            XCTAssertFalse(NativeBudsSettingsWire.permittedWrite(P.frame(command: frame.command, payload: Array(frame.payload))))
        }
    }
    func testTypedFitResultsMuteEchoAndStopIndicationDoNotInventACKSemantics() {
        for l in UInt8(0)...2 { for r in UInt8(0)...2 { XCTAssertNotNil(NativeBudsToolsPacket.fitResult(f(0x9E, [l, r]))) } }
        for invalid in [f(0x9E), f(0x9E, [1]), f(0x9E, [3, 1]), f(0x9E, [1, 1, 1]), f(0x42, [0x9D, 1])] {
            XCTAssertNil(NativeBudsToolsPacket.fitResult(invalid))
        }
        XCTAssertTrue(NativeBudsToolsPacket.muteConfirmed(f(0x42, [0xA2, 0, 1]), parameters: [0, 1]))
        XCTAssertTrue(NativeBudsToolsPacket.muteConfirmed(f(0xA3, [0, 1]), parameters: [0, 1]))
        XCTAssertFalse(NativeBudsToolsPacket.muteConfirmed(f(0x42, [0xA2, 0]), parameters: [0, 1]))
        XCTAssertTrue(NativeBudsToolsPacket.stopped(f(0xA1, [99])))
        XCTAssertFalse(NativeBudsToolsPacket.stopped(f(0x42, [0xA1])))
    }
    func testBasicAndExtendedPlacementsUseDifferentOffsetsAndRejectUnknownValues() {
        let basic = f(0x60, [1, 0, 0, 0, 0, 0x12, 0x43])
        XCTAssertEqual(NativeBudsToolsPacket.placements(basic)?.0, .wearing)
        XCTAssertEqual(NativeBudsToolsPacket.placements(basic)?.1, .idle)
        let extended = f(0x61, [1, 0, 0, 0, 0, 0x12, 0x43])
        XCTAssertEqual(NativeBudsToolsPacket.placements(extended)?.0, .closedCase)
        XCTAssertEqual(NativeBudsToolsPacket.placements(extended)?.1, .inCase)
        XCTAssertNil(NativeBudsToolsPacket.placements(f(0x60, [1, 0, 0, 0, 0])))
        XCTAssertNil(NativeBudsToolsPacket.placements(f(0x60, [1, 0, 0, 0, 0, 0x51])))
        XCTAssertNil(NativeBudsToolsPacket.placements(f(0x60, [5, 0, 0, 0, 0, 0x11])))
    }
    func testFreshnessAndOppositeWearGatesButStopRemainsPossibleWithoutWearReading() {
        XCTAssertTrue(NativeBudsToolsPacket.startAllowed(f(0xA6), placements: (.idle, .idle), observedAt: 0, now: 5))
        XCTAssertFalse(NativeBudsToolsPacket.startAllowed(f(0xA6), placements: (.idle, .idle), observedAt: 0, now: 5.1))
        XCTAssertFalse(NativeBudsToolsPacket.startAllowed(f(0xA6), placements: (.wearing, .idle), observedAt: 0, now: 0))
        XCTAssertTrue(NativeBudsToolsPacket.startAllowed(f(0x9D, [1]), placements: (.wearing, .wearing), observedAt: 0, now: 0))
        XCTAssertFalse(NativeBudsToolsPacket.startAllowed(f(0x9D, [1]), placements: (.wearing, .idle), observedAt: 0, now: 0))
        XCTAssertTrue(NativeBudsToolsPacket.startAllowed(f(0x9D, [0]), placements: nil, observedAt: nil, now: 100))
        XCTAssertTrue(NativeBudsToolsPacket.startAllowed(f(0xA1), placements: nil, observedAt: nil, now: 100))
    }
    func testHelperWatchdogFindDeadlineCancellationAndRemoteStopAreIndependentOfParentACKs() {
        var guardState = NativeBudsToolsWatchdog()
        guardState.submitted(f(0xA6), at: 10)
        XCTAssertNil(guardState.due(at: 189.9))
        XCTAssertEqual(guardState.due(at: 190).flatMap(P.decodeCompleteFrame)?.command, 0xA1)
        XCTAssertNil(guardState.due(at: 200)); XCTAssertNil(guardState.requestStop())
        XCTAssertNotNil(guardState.cleanup, "Closing retries stop even after a watchdog request")
        guardState.observed(f(0x42, [0xA1])); XCTAssertNotNil(guardState.cleanup)
        guardState.observed(f(0xA1)); XCTAssertNil(guardState.cleanup)
        guardState.submitted(f(0xA6), at: 20)
        XCTAssertNotNil(guardState.requestStop()); XCTAssertNil(guardState.requestStop())
    }
    func testHelperWatchdogFitDeadlineDoesNotClaimFirmwareAcousticStop() {
        var guardState = NativeBudsToolsWatchdog(); guardState.submitted(f(0x9D, [1]), at: 10)
        XCTAssertNil(guardState.due(at: 17.9))
        let stop = guardState.due(at: 18).flatMap(P.decodeCompleteFrame)
        XCTAssertEqual(stop?.command, 0x9D); XCTAssertEqual(stop?.payload, Data([0]))
        XCTAssertNotNil(guardState.cleanup)
        guardState.observed(f(0x9E, [1, 1])); XCTAssertNotNil(guardState.cleanup)
    }
}
