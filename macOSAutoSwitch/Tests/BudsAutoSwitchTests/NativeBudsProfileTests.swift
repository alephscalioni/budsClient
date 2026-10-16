import XCTest
@testable import BudsAutoSwitch

final class NativeBudsProfileTests: XCTestCase {
    func testBuds4StandardIsNotProAndCannotUseProArtworkOrSettings() {
        let profile = NativeBudsProfile.resolve(model: "Buds4", name: "Buds4 Pro de exemplo")
        XCTAssertEqual(profile.title, "Galaxy Buds4")
        XCTAssertEqual(profile.artwork("Buds4White"), "Buds4White")
        XCTAssertNil(profile.artwork("Buds4ProWhite"))
        XCTAssertFalse(profile.nativeSettingsImplemented)
        XCTAssertFalse(profile.handoffValidated)
    }
    func testAliasIsOnlyPresentationAndKnownModelWins() {
        XCTAssertEqual(NativeBudsProfile.resolve(model: nil, name: "Buds4 de exemplo").model, "Buds4")
        let unknown = NativeBudsProfile.resolve(model: "Buds2", name: "Buds3 Pro")
        XCTAssertFalse(unknown.nativeSettingsImplemented)
        XCTAssertNil(unknown.artwork("Buds3ProSilver"))
    }
    func testBuds3ProPresentationKeepsMatchingOriginalArtwork() {
        let profile = NativeBudsProfile.resolve(model: "Buds3Pro", name: "Fone")
        XCTAssertTrue(profile.nativeSettingsImplemented)
        XCTAssertEqual(profile.artwork("Buds3ProSilver"), "Buds3ProSilver")
        XCTAssertNil(profile.artwork("../../secret"))
    }
    func testBannerFallbackArtworkFollowsPhysicalModelBeforeAlias() {
        XCTAssertEqual(NativeBudsProfile.resolve(model: "Buds4", name: "Buds3 Pro").defaultArtwork, "Buds4White")
        XCTAssertEqual(NativeBudsProfile.resolve(model: "Buds4Pro", name: "Fones de exemplo").defaultArtwork, "Buds4ProWhite")
        XCTAssertEqual(NativeBudsProfile.resolve(model: nil, name: "Buds4 de exemplo").defaultArtwork, "Buds4White")
        XCTAssertNil(NativeBudsProfile.resolve(model: "Desconhecido", name: "Buds3 Pro").defaultArtwork)
    }
}
