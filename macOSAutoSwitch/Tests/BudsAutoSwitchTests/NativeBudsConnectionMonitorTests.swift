import XCTest
@testable import BudsAutoSwitch

@MainActor private final class BannerFakeLinkObserver: NativeBudsPassiveLinkObserving {
    var callbacks: [(NativeBudsPassiveLinkSample) -> Void] = []
    var addresses: [String] = []
    var cancellations = 0
    var available = true

    func observe(address: String, receive: @escaping (NativeBudsPassiveLinkSample) -> Void) -> (() -> Void)? {
        addresses.append(address); callbacks.append(receive)
        guard available else { return nil }
        return { [weak self] in self?.cancellations += 1 }
    }
}

final class NativeBudsConnectionMonitorTests: XCTestCase {
    private let buds = "AA:BB:CC:DD:EE:01"
    private let other = "AA:BB:CC:DD:EE:02"

    @MainActor private func fixture() -> (BannerFakeLinkObserver, NativeBudsConnectionMonitor,
                                         () -> [NativeConnectionBannerEvent], () -> [NativeConnectionBannerPresentation]) {
        let fake = BannerFakeLinkObserver()
        var events: [NativeConnectionBannerEvent] = [], presentations: [NativeConnectionBannerPresentation] = []
        var policy = NativeConnectionBannerPolicy()
        let monitor = NativeBudsConnectionMonitor(observer: fake, now: { 100 }, onEvent: {
            events.append($0)
            if let result = policy.presentation(for: $0, portuguese: true) { presentations.append(result) }
        }, onLinkState: { policy.observeLink(address: $0, connected: $1, at: $2) })
        return (fake, monitor, { events }, { presentations })
    }

    private func sample(_ connected: Bool, _ sequence: UInt64, at time: Double = 100,
                        address: String? = nil, baseline: Bool = false) -> NativeBudsPassiveLinkSample {
        .init(address: address ?? buds, connected: connected, capturedAt: time, sequence: sequence,
              origin: baseline ? .baseline : .notification)
    }

    @MainActor func testLaunchAlreadyConnectedAndRepeatedSnapshotsStaySilent() {
        let (fake, monitor, events, presentations) = fixture()
        XCTAssertTrue(fake.addresses.isEmpty) // construction has no effects
        monitor.select(address: buds, name: "Buds")
        fake.callbacks[0](sample(true, 0, baseline: true))
        fake.callbacks[0](sample(true, 1, baseline: true))
        for i in 2...20 { fake.callbacks[0](sample(true, UInt64(i))) }
        XCTAssertTrue(events().isEmpty); XCTAssertTrue(presentations().isEmpty)
        monitor.stop()
    }

    @MainActor func testInitialDisconnectedThenNewConnectionShowsOnceAcrossNotificationBurst() {
        let (fake, monitor, events, presentations) = fixture()
        monitor.select(address: buds, name: "Galaxy Buds3 Pro")
        fake.callbacks[0](sample(false, 0, baseline: true))
        for i in 1...20 { fake.callbacks[0](sample(true, UInt64(i))) }
        XCTAssertEqual(events().map(\.kind), [.directMacConnection])
        XCTAssertEqual(presentations().map(\.destination), ["Conectado ao Mac"])
        monitor.stop()
    }

    @MainActor func testDisconnectIsSilentAndReconnectIsANewEvent() {
        let (fake, monitor, events, presentations) = fixture()
        monitor.select(address: buds, name: "Buds")
        fake.callbacks[0](sample(false, 0, baseline: true))
        fake.callbacks[0](sample(true, 1))
        fake.callbacks[0](sample(false, 2))
        XCTAssertEqual(events().count, 1)
        fake.callbacks[0](sample(true, 3))
        XCTAssertEqual(events().count, 2); XCTAssertEqual(presentations().count, 2)
        monitor.stop()
    }

    @MainActor func testSelectionChangeRejectsOldCallbacksEvenWhenSelectingSameBudsAgain() {
        let (fake, monitor, events, _) = fixture()
        monitor.select(address: buds, name: "First")
        fake.callbacks[0](sample(false, 0, baseline: true))
        monitor.select(address: other, name: "Other")
        fake.callbacks[0](sample(true, 1))
        monitor.select(address: buds, name: "Current")
        fake.callbacks[0](sample(true, 2))
        fake.callbacks[2](sample(false, 0, baseline: true))
        fake.callbacks[2](sample(true, 1))
        XCTAssertEqual(events().count, 1); XCTAssertEqual(events().first?.name, "Current")
        XCTAssertEqual(fake.cancellations, 2)
        monitor.stop()
    }

    @MainActor func testCancellationIgnoresQueuedAndFutureCallbacks() {
        let (fake, monitor, events, _) = fixture()
        monitor.select(address: buds, name: "Buds")
        fake.callbacks[0](sample(false, 0, baseline: true))
        monitor.stop(); monitor.stop()
        fake.callbacks[0](sample(true, 1))
        XCTAssertTrue(events().isEmpty); XCTAssertEqual(fake.cancellations, 1)
    }

    @MainActor func testStaleFutureOutOfOrderAndWrongDeviceSamplesAreIgnored() {
        let (fake, monitor, events, _) = fixture()
        monitor.select(address: buds, name: "Buds")
        fake.callbacks[0](sample(false, 10, baseline: true))
        for invalid in [sample(true, 9), sample(true, 10), sample(true, 11, at: 99),
                        sample(true, 11, at: 101), sample(true, 11, at: .nan),
                        sample(true, 11, address: other)] { fake.callbacks[0](invalid) }
        XCTAssertTrue(events().isEmpty)
        fake.callbacks[0](sample(true, 11))
        XCTAssertEqual(events().count, 1)
        fake.callbacks[0](sample(false, 12, at: 99))
        fake.callbacks[0](sample(true, 13))
        XCTAssertEqual(events().count, 1)
        monitor.stop()
    }

    @MainActor func testNotificationWithoutBaselineAndDelayedBaselineCannotManufactureTransition() {
        let (fake, monitor, events, _) = fixture()
        monitor.select(address: buds, name: "Buds")
        fake.callbacks[0](sample(true, 0))
        XCTAssertTrue(events().isEmpty)
        fake.callbacks[0](sample(true, 1, baseline: true))
        fake.callbacks[0](sample(false, 2, baseline: true))
        fake.callbacks[0](sample(true, 3))
        XCTAssertTrue(events().isEmpty)
        monitor.stop()
    }

    @MainActor func testRepeatedSelectionReadsDoNotRestartAndUpdatedNameIsUsed() {
        let (fake, monitor, events, _) = fixture()
        monitor.select(address: buds, name: "Old")
        fake.callbacks[0](sample(false, 0, baseline: true))
        for _ in 0..<20 { monitor.select(address: "aa-bb-cc-dd-ee-01", name: "New") }
        XCTAssertEqual(fake.addresses.count, 1)
        fake.callbacks[0](sample(true, 1))
        XCTAssertEqual(events().first?.name, "New")
        monitor.stop()
    }

    @MainActor func testInvalidSelectionAndObservationFailureStaySilent() {
        let (fake, monitor, events, _) = fixture()
        for address in ["", "phone", "00:00:00:00:00:00"] { monitor.select(address: address, name: "Buds") }
        XCTAssertTrue(fake.addresses.isEmpty)
        fake.available = false
        monitor.select(address: buds, name: "Buds")
        fake.callbacks[0](sample(false, 0, baseline: true))
        fake.callbacks[0](sample(true, 1))
        XCTAssertTrue(events().isEmpty)
    }

    @MainActor func testDeinitCancelsObservationWithoutEvent() async {
        let fake = BannerFakeLinkObserver()
        var events: [NativeConnectionBannerEvent] = []
        var monitor: NativeBudsConnectionMonitor? = .init(observer: fake, onEvent: { events.append($0) },
                                                        onLinkState: { _, _, _ in })
        monitor?.select(address: buds, name: "Buds")
        monitor = nil
        for _ in 0..<10 where fake.cancellations == 0 { await Task.yield() }
        XCTAssertEqual(fake.cancellations, 1); XCTAssertTrue(events.isEmpty)
    }

    @MainActor func testCancellationDuringLinkReceiptSuppressesThePendingBanner() {
        let fake = BannerFakeLinkObserver()
        var events: [NativeConnectionBannerEvent] = []
        var monitor: NativeBudsConnectionMonitor!
        monitor = .init(observer: fake, now: { 100 }, onEvent: { events.append($0) },
                        onLinkState: { _, connected, _ in if connected { monitor.stop() } })
        monitor.select(address: buds, name: "Buds")
        fake.callbacks[0](sample(false, 0, baseline: true))
        fake.callbacks[0](sample(true, 1))
        XCTAssertTrue(events.isEmpty); XCTAssertEqual(fake.cancellations, 1)
        monitor = nil
    }

    @MainActor func testOlderCaptureCannotUndoANewerTransitionEvenWithHigherSequence() {
        let fake = BannerFakeLinkObserver()
        var now: Double = 10
        var events: [NativeConnectionBannerEvent] = []
        let monitor = NativeBudsConnectionMonitor(observer: fake, now: { now },
            onEvent: { events.append($0) }, onLinkState: { _, _, _ in })
        monitor.select(address: buds, name: "Buds")
        fake.callbacks[0](sample(false, 0, at: 10, baseline: true))
        now = 20
        fake.callbacks[0](sample(true, 1, at: 20))
        now = 30
        fake.callbacks[0](sample(false, 2, at: 19))
        fake.callbacks[0](sample(true, 3, at: 30))
        XCTAssertEqual(events.count, 1)
        monitor.stop()
    }
}
