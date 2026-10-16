import XCTest
@testable import BudsAutoSwitch

@MainActor private final class AsyncBannerLinkSource {
    var time: TimeInterval = 10
    var reads: [String] = []
    var receipts: [NativeBudsAsyncPassiveLinkObserver.Receipt] = []
    var gates: [CheckedContinuation<Bool, Error>] = []
    var cancellations = 0
    var available = true

    func observer() -> NativeBudsAsyncPassiveLinkObserver {
        .init(baseline: { address in
            self.reads.append(address)
            return try await withCheckedThrowingContinuation { self.gates.append($0) }
        }, notifications: { _, receipt in
            self.receipts.append(receipt)
            guard self.available else { return nil }
            return { self.cancellations += 1 }
        }, now: { self.time })
    }

    func settle() async { for _ in 0..<50 { await Task.yield() } }
}

final class NativeBudsAsyncPassiveLinkObserverTests: XCTestCase {
    private let buds = "AA:BB:CC:DD:EE:01"
    private let other = "AA:BB:CC:DD:EE:02"

    @MainActor func testOneFreshAsyncBaselinePerSelectionAndNoPeriodicReads() async {
        let fake = AsyncBannerLinkSource()
        var events: [NativeConnectionBannerEvent] = []
        let monitor = NativeBudsConnectionMonitor(observer: fake.observer(), now: { fake.time },
            onEvent: { events.append($0) }, onLinkState: { _, _, _ in })
        XCTAssertTrue(fake.reads.isEmpty)
        monitor.select(address: buds, name: "Buds"); await fake.settle()
        XCTAssertEqual(fake.reads, [buds])
        fake.gates[0].resume(returning: true); await fake.settle()
        for _ in 0..<20 {
            fake.time += 1
            monitor.select(address: "aa-bb-cc-dd-ee-01", name: "Buds")
            _ = fake.receipts[0](true, fake.time)
        }
        await fake.settle()
        XCTAssertEqual(fake.reads.count, 1); XCTAssertTrue(events.isEmpty)
        fake.time += 1; _ = fake.receipts[0](false, fake.time)
        fake.time += 1; _ = fake.receipts[0](true, fake.time)
        await fake.settle()
        XCTAssertEqual(events.map(\.kind), [.directMacConnection])
        XCTAssertEqual(fake.reads.count, 1)
        monitor.stop(); XCTAssertEqual(fake.cancellations, 1)
    }

    @MainActor func testNotificationsDuringReadBecomeSilentBaselineBeforeAnyTransition() async {
        let fake = AsyncBannerLinkSource()
        var samples: [NativeBudsPassiveLinkSample] = []
        let cancel = fake.observer().observe(address: buds) { samples.append($0) }
        await fake.settle()
        fake.time = 11; _ = fake.receipts[0](false, fake.time)
        fake.time = 12; _ = fake.receipts[0](true, fake.time)
        await fake.settle()
        XCTAssertTrue(samples.isEmpty, "Notifications cannot overtake the initial baseline")
        fake.gates[0].resume(returning: false) // stale passive query result
        await fake.settle()
        XCTAssertEqual(samples.count, 1); XCTAssertEqual(samples[0].origin, .baseline)
        XCTAssertTrue(samples[0].connected); XCTAssertEqual(samples[0].capturedAt, 12)
        fake.time = 13; _ = fake.receipts[0](false, fake.time)
        fake.time = 14; _ = fake.receipts[0](true, fake.time)
        await fake.settle()
        XCTAssertEqual(samples.map(\.connected), [true, false, true])
        XCTAssertEqual(samples.map(\.sequence), [2, 3, 4])
        XCTAssertEqual(samples.dropFirst().map(\.origin), [.notification, .notification])
        cancel?()
    }

    @MainActor func testIngressOrderSurvivesQueuedDeliveryAndRejectsOlderCaptures() async {
        let fake = AsyncBannerLinkSource()
        var samples: [NativeBudsPassiveLinkSample] = []
        let cancel = fake.observer().observe(address: buds) { samples.append($0) }
        await fake.settle(); fake.gates[0].resume(returning: false); await fake.settle()
        // All callbacks occur before any MainActor delivery task can execute.
        XCTAssertNotNil(fake.receipts[0](true, 12))
        XCTAssertNil(fake.receipts[0](false, 11))
        XCTAssertNil(fake.receipts[0](false, .nan))
        XCTAssertNotNil(fake.receipts[0](false, 12))
        XCTAssertNotNil(fake.receipts[0](true, 13))
        await fake.settle()
        XCTAssertEqual(samples.map(\.connected), [false, true, false, true])
        XCTAssertEqual(samples.map(\.sequence), [0, 1, 2, 3])
        cancel?()
    }

    @MainActor func testFailedBaselineStaysUnknownAndFirstNotificationSeedsSilently() async {
        let fake = AsyncBannerLinkSource()
        var events: [NativeConnectionBannerEvent] = []
        let monitor = NativeBudsConnectionMonitor(observer: fake.observer(), now: { fake.time },
            onEvent: { events.append($0) }, onLinkState: { _, _, _ in })
        monitor.select(address: buds, name: "Buds"); await fake.settle()
        fake.gates[0].resume(throwing: NativeBudsError(message: "snapshot-unavailable"))
        await fake.settle()
        fake.time = 11; _ = fake.receipts[0](true, fake.time); await fake.settle()
        XCTAssertTrue(events.isEmpty, "Unknown must not be fabricated as disconnected")
        fake.time = 12; _ = fake.receipts[0](false, fake.time)
        fake.time = 13; _ = fake.receipts[0](true, fake.time); await fake.settle()
        XCTAssertEqual(events.count, 1); XCTAssertEqual(fake.reads.count, 1)
        monitor.stop()
    }

    @MainActor func testCancellationFencesNoncooperativeBaselineAndQueuedReceipts() async {
        let fake = AsyncBannerLinkSource()
        var samples: [NativeBudsPassiveLinkSample] = []
        let cancel = fake.observer().observe(address: buds) { samples.append($0) }
        await fake.settle()
        _ = fake.receipts[0](true, 11)
        cancel?()
        XCTAssertNil(fake.receipts[0](false, 12))
        fake.gates[0].resume(returning: false); await fake.settle()
        XCTAssertTrue(samples.isEmpty); XCTAssertEqual(fake.cancellations, 1)
    }

    @MainActor func testAsyncBaselinesCannotCrossSelectionGenerationsEvenForSameAddress() async {
        let fake = AsyncBannerLinkSource()
        var events: [NativeConnectionBannerEvent] = []
        let monitor = NativeBudsConnectionMonitor(observer: fake.observer(), now: { fake.time },
            onEvent: { events.append($0) }, onLinkState: { _, _, _ in })
        monitor.select(address: buds, name: "Old"); await fake.settle()
        fake.time = 11; monitor.select(address: other, name: "Other"); await fake.settle()
        fake.time = 12; monitor.select(address: buds, name: "Current"); await fake.settle()
        fake.gates[0].resume(returning: false); fake.gates[1].resume(returning: false)
        fake.gates[2].resume(returning: false); await fake.settle()
        XCTAssertNil(fake.receipts[0](true, 13)); XCTAssertNil(fake.receipts[1](true, 13))
        fake.time = 13; _ = fake.receipts[2](true, fake.time); await fake.settle()
        XCTAssertEqual(events.count, 1); XCTAssertEqual(events.first?.name, "Current")
        XCTAssertEqual(fake.reads, [buds, other, buds]); XCTAssertEqual(fake.cancellations, 2)
        monitor.stop()
    }

    @MainActor func testCancellationInsideBaselineReceiptFencesSubsequentDelivery() async {
        let fake = AsyncBannerLinkSource()
        var samples: [NativeBudsPassiveLinkSample] = []
        var cancel: (() -> Void)?
        cancel = fake.observer().observe(address: buds) {
            samples.append($0); cancel?()
        }
        await fake.settle(); fake.gates[0].resume(returning: false); await fake.settle()
        XCTAssertNil(fake.receipts[0](true, 11)); await fake.settle()
        XCTAssertEqual(samples.count, 1); XCTAssertEqual(samples[0].origin, .baseline)
        XCTAssertEqual(fake.cancellations, 1)
    }

    @MainActor func testNotificationRegistrationFailureDoesNotReadOrDeliverBaseline() async {
        let fake = AsyncBannerLinkSource(); fake.available = false
        var samples: [NativeBudsPassiveLinkSample] = []
        XCTAssertNil(fake.observer().observe(address: buds) { samples.append($0) })
        await fake.settle()
        XCTAssertTrue(fake.reads.isEmpty); XCTAssertNil(fake.receipts[0](true, 11))
        XCTAssertTrue(samples.isEmpty)
    }
}
