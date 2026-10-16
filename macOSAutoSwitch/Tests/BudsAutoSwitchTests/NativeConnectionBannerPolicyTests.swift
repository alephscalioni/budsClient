import XCTest
@testable import BudsAutoSwitch

final class NativeConnectionBannerPolicyTests: XCTestCase {
    private let buds = "AA:BB:CC:DD:EE:01"
    private let otherBuds = "AA:BB:CC:DD:EE:02"
    private let phone = "22:33:44:55:66:77"

    private func event(_ kind: NativeConnectionBannerEvent.Kind, at time: TimeInterval = 1,
                       id: UUID = UUID()) -> NativeConnectionBannerEvent {
        .init(id: id, address: buds, name: "Galaxy Buds3 Pro", kind: kind, occurredAt: time)
    }

    func testClassifiesOnlyTheThreeCompletedEvents() throws {
        for (kind, symbol) in [(NativeConnectionBannerEvent.Kind.directMacConnection, "laptopcomputer"),
                               (.acquiredFromOtherDevice, "arrow.down.left.circle"),
                               (.departedFromMac(destination: nil), "arrow.up.right.circle")] {
            var policy = NativeConnectionBannerPolicy()
            let result = try XCTUnwrap(policy.presentation(for: event(kind), language: .portuguese))
            XCTAssertEqual(result.systemImage, symbol)
            XCTAssertEqual(result.destination, kind == .departedFromMac(destination: nil)
                ? "Desconectado do Mac · Conectado a outro dispositivo" : "Conectado ao Mac")
        }
    }

    func testLegacyModelAndConnectedEntryShareExactlyOnceSuppressionWithoutTimeout() throws {
        var policy = NativeConnectionBannerPolicy()
        XCTAssertNotNil(policy.presentation(for: event(.directMacConnection)))
        let legacy = try XCTUnwrap(NativeConnectionBannerEvent.legacy(address: buds, name: "Buds",
            destination: "Conectado ao Mac", occurredAt: 100))
        XCTAssertNil(policy.presentation(for: legacy))
        XCTAssertNil(policy.presentation(for: event(.directMacConnection, at: 1_000)))
    }

    func testModelFirstThenDirectNotificationDoesNotRepeat() {
        var policy = NativeConnectionBannerPolicy()
        XCTAssertNotNil(policy.presentation(for: event(.acquiredFromOtherDevice)))
        XCTAssertNil(policy.presentation(for: event(.directMacConnection, at: 2)))
    }

    func testVerifiedOppositeTransitionsRearmEvenWithinOldDebounceWindow() {
        var policy = NativeConnectionBannerPolicy()
        XCTAssertNotNil(policy.presentation(for: event(.acquiredFromOtherDevice)))
        XCTAssertNotNil(policy.presentation(for: event(.departedFromMac(destination: nil), at: 1.1)))
        XCTAssertNil(policy.presentation(for: event(.departedFromMac(destination: nil), at: 1.2)))
        XCTAssertNotNil(policy.presentation(for: event(.acquiredFromOtherDevice, at: 1.3)))
    }

    func testSilentPhysicalLossRearmsActualReconnect() {
        var policy = NativeConnectionBannerPolicy()
        XCTAssertNotNil(policy.presentation(for: event(.directMacConnection)))
        policy.observeLink(address: buds, connected: false, at: 1.1)
        XCTAssertNotNil(policy.presentation(for: event(.directMacConnection, at: 1.2)))
        XCTAssertNil(policy.presentation(for: event(.acquiredFromOtherDevice, at: 1.3)))
    }

    func testPhysicalReleaseDoesNotRepeatVerifiedDeparture() {
        var policy = NativeConnectionBannerPolicy()
        XCTAssertNotNil(policy.presentation(for: event(.departedFromMac(destination: nil))))
        policy.observeLink(address: buds, connected: false, at: 2)
        XCTAssertNil(policy.presentation(for: event(.departedFromMac(destination: nil), at: 3)))
    }

    func testStartupBaselineAndRepeatedPassiveReadsProduceNoPresentation() {
        var policy = NativeConnectionBannerPolicy()
        policy.observeLink(address: buds, connected: true, at: 0)
        policy.observeLink(address: buds, connected: true, at: 1)
        // Baselines/reads neither emit nor consume an actual acquisition event.
        XCTAssertNotNil(policy.presentation(for: event(.acquiredFromOtherDevice, at: 2)))
    }

    func testFailedPendingCancelledAndSettingsTextCannotBecomeEvents() {
        for text in ["Conectando ao Mac", "Falha", "Cancelado", "Atualizado", "Conectado a S25 Ultra", ""] {
            XCTAssertNil(NativeConnectionBannerEvent.legacy(address: buds, name: "Buds",
                destination: text, occurredAt: 1))
        }
    }

    func testGenericGalaxyDoesNotEstablishNamedDestination() throws {
        var policy = NativeConnectionBannerPolicy()
        let event = try XCTUnwrap(NativeConnectionBannerEvent.legacy(address: buds, name: "Buds",
            destination: "Conectado ao Galaxy", occurredAt: 1))
        XCTAssertEqual(policy.presentation(for: event, language: .portuguese)?.destination,
                       "Desconectado do Mac · Conectado a outro dispositivo")
    }

    func testNamedDestinationRequiresMatchingBudsAndTransferReceipt() throws {
        let id = UUID()
        let destination = try XCTUnwrap(NativeConnectionBannerEvent.VerifiedDestination(
            budsAddress: buds, peerAddress: phone, name: " S25 Ultra ", transferID: id))
        var policy = NativeConnectionBannerPolicy()
        XCTAssertEqual(policy.presentation(for: event(.departedFromMac(destination: destination), id: id),
            language: .portuguese)?.destination, "Desconectado do Mac · Conectado a S25 Ultra")

        for wrong in [NativeConnectionBannerEvent.VerifiedDestination(budsAddress: otherBuds,
                          peerAddress: phone, name: "S25 Ultra", transferID: id),
                      NativeConnectionBannerEvent.VerifiedDestination(budsAddress: buds,
                          peerAddress: phone, name: "S25 Ultra", transferID: UUID())] {
            var policy = NativeConnectionBannerPolicy()
            XCTAssertEqual(policy.presentation(for: event(.departedFromMac(destination: wrong), id: id),
                language: .portuguese)?.destination, "Desconectado do Mac · Conectado a outro dispositivo")
        }
    }

    func testEnglishDepartureIncludesMacLossWithoutInventingDestination() {
        var policy = NativeConnectionBannerPolicy()
        XCTAssertEqual(policy.presentation(for: event(.departedFromMac(destination: nil)),
            language: .english)?.destination, "Disconnected from Mac · Connected to another device")
    }

    func testIdentityArrivingLateDoesNotRepeatAnAlreadyAnnouncedDeparture() throws {
        let id = UUID()
        let peer = try XCTUnwrap(NativeConnectionBannerEvent.VerifiedDestination(
            budsAddress: buds, peerAddress: phone, name: "Phone", transferID: id))
        var policy = NativeConnectionBannerPolicy()
        XCTAssertNotNil(policy.presentation(for: event(.departedFromMac(destination: nil), id: id)))
        XCTAssertNil(policy.presentation(for: event(.departedFromMac(destination: peer), at: 2, id: id)))
    }

    func testStaleEventsAndOldPhysicalSamplesCannotReverseNewState() {
        var policy = NativeConnectionBannerPolicy()
        XCTAssertNotNil(policy.presentation(for: event(.acquiredFromOtherDevice, at: 10)))
        XCTAssertNil(policy.presentation(for: event(.departedFromMac(destination: nil), at: 9)))
        policy.observeLink(address: buds, connected: false, at: 8)
        XCTAssertNil(policy.presentation(for: event(.directMacConnection, at: 11)))
    }

    func testAddressNormalizationDedupesAliasesAndKeepsDevicesIndependent() {
        var policy = NativeConnectionBannerPolicy()
        XCTAssertNotNil(policy.presentation(for: event(.directMacConnection)))
        XCTAssertNil(policy.presentation(for: .init(address: "aa-bb-cc-dd-ee-01", name: "Buds",
            kind: .directMacConnection, occurredAt: 2)))
        XCTAssertNotNil(policy.presentation(for: .init(address: otherBuds, name: "Buds",
            kind: .directMacConnection, occurredAt: 2)))
    }

    func testRejectsUnknownAddressesAndNonfiniteTime() {
        for address in ["", "unknown", "AA:BB", "00:00:00:00:00:00", "FF:FF:FF:FF:FF:FF"] {
            var policy = NativeConnectionBannerPolicy()
            XCTAssertNil(policy.presentation(for: .init(address: address, name: "Buds",
                kind: .directMacConnection, occurredAt: 1)))
        }
        for time in [Double.nan, .infinity, -.infinity, -1] {
            var policy = NativeConnectionBannerPolicy()
            XCTAssertNil(policy.presentation(for: event(.directMacConnection, at: time)))
        }
        XCTAssertNil(NativeConnectionBannerEvent.VerifiedDestination(
            budsAddress: buds, peerAddress: phone, name: " \n ", transferID: UUID()))
    }
}

final class AppLanguageTests: XCTestCase {
    func testResolvesPreferredLanguages() {
        XCTAssertEqual(AppLanguage.resolve(["pt-BR"]), .portuguese)
        XCTAssertEqual(AppLanguage.resolve(["zh-Hant-TW"]), .chineseTraditional)
        XCTAssertEqual(AppLanguage.resolve(["zh-CN"]), .chineseSimplified)
        XCTAssertEqual(AppLanguage.resolve(["xx", "ja-JP"]), .japanese)
        XCTAssertEqual(AppLanguage.resolve([]), .english)
    }

    func testSideLabelsAreDistinctAndComplete() {
        for language in AppLanguage.allCases {
            XCTAssertNotEqual(LocalizedText.left.string(language), LocalizedText.right.string(language), "\(language)")
            XCTAssertNotNil(LocalizedText.disconnected(to: "x", language).range(of: "x"))
        }
    }
}
