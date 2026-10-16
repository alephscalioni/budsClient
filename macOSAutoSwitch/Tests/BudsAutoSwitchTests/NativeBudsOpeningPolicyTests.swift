import XCTest
@testable import BudsAutoSwitch

final class NativeBudsOpeningPolicyTests: XCTestCase {
    func testPairedServiceOpensWithoutStartingSDP() {
        var plan = NativeBudsOpeningPolicy()
        plan.begin(cachedChannel: 29, bluetoothConnected: true)
        XCTAssertEqual(plan.phase, .channel)
        XCTAssertEqual(plan.serviceAction, .openChannel(29))
        XCTAssertEqual(plan.channelAttempts, 1)
        XCTAssertNil(plan.channelCompleted(success: true))
        XCTAssertEqual(plan.phase, .open)
    }

    func testExplicitCachedChannelFailureRefreshesServiceOnce() {
        var plan = NativeBudsOpeningPolicy()
        plan.begin(cachedChannel: 27, bluetoothConnected: true)
        XCTAssertEqual(plan.channelCompleted(success: false), .queryService)
        XCTAssertEqual(plan.phase, .discovery)
        XCTAssertEqual(plan.discoveryCompleted(channel: 29), .openChannel(29))
        XCTAssertEqual(plan.channelAttempts, 2)
        XCTAssertNil(plan.channelCompleted(success: true))
        XCTAssertEqual(plan.phase, .open)
    }

    func testBluetoothCompletionUsesCachedServiceWithoutDiscovery() {
        var plan = NativeBudsOpeningPolicy()
        plan.begin(cachedChannel: 29, bluetoothConnected: false)
        XCTAssertEqual(plan.phase, .bluetooth)
        XCTAssertEqual(plan.timeout, 10)
        XCTAssertEqual(plan.bluetoothCompleted(success: true), .openChannel(29))
        XCTAssertEqual(plan.timeout, 8)
    }

    func testMissingCacheQueriesBeforeOpeningAndUsesSeparateBudget() {
        var plan = NativeBudsOpeningPolicy()
        plan.begin(cachedChannel: nil, bluetoothConnected: false)
        XCTAssertEqual(plan.bluetoothCompleted(success: true), .queryService)
        XCTAssertEqual(plan.timeout, 4)
        XCTAssertEqual(plan.discoveryCompleted(channel: 29), .openChannel(29))
        XCTAssertEqual(plan.timeout, 8)
    }

    func testTimeoutNeverOverlapsAnUnfinishedSDKOperation() {
        for phase in [NativeBudsOpeningPolicy.Phase.bluetooth, .discovery, .channel] {
            var plan = NativeBudsOpeningPolicy()
            plan.begin(cachedChannel: phase == .discovery ? nil : 29,
                       bluetoothConnected: phase != .bluetooth)
            XCTAssertEqual(plan.phase, phase)
            let attempts = plan.channelAttempts
            XCTAssertEqual(plan.timedOut(), .fail)
            XCTAssertEqual(plan.phase, .failed)
            XCTAssertEqual(plan.channelAttempts, attempts)
            XCTAssertEqual(plan.timedOut(), .fail)
        }
    }

    func testFreshChannelFailureDoesNotLoopBackToCache() {
        var plan = NativeBudsOpeningPolicy()
        plan.begin(cachedChannel: 29, bluetoothConnected: true)
        XCTAssertEqual(plan.channelCompleted(success: false), .queryService)
        XCTAssertEqual(plan.discoveryCompleted(channel: 29), .openChannel(29))
        XCTAssertEqual(plan.channelCompleted(success: false), .fail)
        XCTAssertEqual(plan.channelAttempts, 2)
        XCTAssertEqual(plan.phase, .failed)
    }

    func testMissingOrInvalidServiceDoesNotOpenArbitraryChannel() {
        for cached: UInt8? in [nil, 0, 31, 255] {
            for fresh: UInt8? in [nil, 0, 31, 255] {
                var plan = NativeBudsOpeningPolicy()
                plan.begin(cachedChannel: cached, bluetoothConnected: true)
                XCTAssertEqual(plan.serviceAction, .queryService)
                XCTAssertEqual(plan.discoveryCompleted(channel: fresh), .fail)
                XCTAssertEqual(plan.channelAttempts, 0)
            }
        }
    }

    func testNoSDPOrChannelAfterUnconfirmedBluetoothConnection() {
        var plan = NativeBudsOpeningPolicy()
        plan.begin(cachedChannel: 29, bluetoothConnected: false)
        XCTAssertEqual(plan.timedOut(), .fail)
        XCTAssertEqual(plan.channelAttempts, 0)
        plan.begin(cachedChannel: 29, bluetoothConnected: false)
        XCTAssertEqual(plan.bluetoothCompleted(success: false), .fail)
        XCTAssertEqual(plan.phase, .failed)
    }

    func testRestartDiscardsPreviousDiscoveryState() {
        var plan = NativeBudsOpeningPolicy()
        plan.begin(cachedChannel: 28, bluetoothConnected: true)
        XCTAssertEqual(plan.channelCompleted(success: false), .queryService)
        XCTAssertEqual(plan.discoveryCompleted(channel: nil), .fail)
        plan.begin(cachedChannel: 29, bluetoothConnected: true)
        XCTAssertEqual(plan.channelAttempts, 1)
        XCTAssertEqual(plan.serviceAction, .openChannel(29))
        XCTAssertEqual(plan.channelCompleted(success: false), .queryService)
    }
}
