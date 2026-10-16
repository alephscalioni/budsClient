import Foundation
import XCTest
@testable import BudsAutoSwitch

@MainActor final class NativeBudsFirmwareCatalogTests: XCTestCase {
    func testCatalogueSeparatesModelsAndNeverCallsUnknownVersionUpToDate() throws {
        let data = Data("""
        [{"model":"Buds3Pro","buildName":"R630XXU0AZG2","region":"XX","bootloaderVersion":"U0"},
         {"model":"Buds4Pro","buildName":"R640XXU0AZG2"},
         {"model":"Buds3Pro","buildName":"R630XXU0AZG2"},
         {"model":"Buds3Pro","buildName":"R630/../../bad"}]
        """.utf8)
        let entries = try NativeBudsFirmwareCatalog.parse(data, model: .buds3Pro)
        XCTAssertEqual(entries.map(\.buildName), ["R630XXU0AZG2"])
        XCTAssertNil(NativeBudsFirmwareCatalog.newer(entries[0].buildName, than: nil))
        XCTAssertNil(NativeBudsFirmwareCatalog.newer(entries[0].buildName, than: "R630KSU0AZD2"))
        XCTAssertTrue(try XCTUnwrap(NativeBudsFirmwareCatalog.newer(entries[0].buildName, than: "R630XXU0AZD2")))
        XCTAssertFalse(try XCTUnwrap(NativeBudsFirmwareCatalog.newer(entries[0].buildName, than: entries[0].buildName)))
    }

    func testAnUnknownInstalledVersionIsNotAZeroOrAnUpdateClaim() {
        let catalogue = NativeBudsFirmwareCatalog(load: { _ in Data("[]".utf8) })
        catalogue.select(address: "fixture", model: "Buds3Pro", installed: "unknown")
        XCTAssertTrue(catalogue.snapshot["installed_version"] is NSNull)
        XCTAssertTrue(catalogue.snapshot["has_update"] is NSNull)
        XCTAssertEqual(catalogue.snapshot["available"] as? Bool, true)
        catalogue.select(address: "fixture", model: "Buds3Pro", installed: "R630XXU0AZG2")
        XCTAssertTrue(catalogue.snapshot["has_update"] is NSNull)
        catalogue.select(address: "fixture", model: "Unverified", installed: "R630XXU0AZG2")
        XCTAssertEqual(catalogue.snapshot["available"] as? Bool, false)
    }

    func testEveryKnownModelHasItsOwnReadOnlyCatalogueIncludingThirteenCharacterFEVersion() throws {
        for profile in SamsungBudsModelProfile.allCases {
            let version = profile.firmwarePrefix + "XXU0AZG2"
            let catalogue = NativeBudsFirmwareCatalog(load: { _ in Data("[]".utf8) })
            catalogue.select(address: "fixture", model: profile.rawValue, installed: version)
            XCTAssertEqual(catalogue.snapshot["available"] as? Bool, true, profile.rawValue)
            XCTAssertEqual(catalogue.snapshot["installed_version"] as? String, version)
            let response = SamsungBudsSettingsPacket.Frame(command: 0xB4, payload: Data(version.utf8), isFragment: false)
            XCTAssertEqual(SamsungBudsFirmwareVersion.version(response, model: profile.rawValue), profile.supportsInfo ? version : nil)
        }
        XCTAssertEqual(NativeBudsFirmwareCatalog.validVersion("R400NXXU0AZG2", model: .budsFe), "R400NXXU0AZG2")
        XCTAssertNil(NativeBudsFirmwareCatalog.validVersion("R400XXU0AZG2", model: .budsFe))
        XCTAssertTrue(try XCTUnwrap(NativeBudsFirmwareCatalog.newer("R400NXXU0AZG2", than: "R400NXXU0AZD2")))
        XCTAssertNil(NativeBudsFirmwareCatalog.newer("R400NXXU0AZG2", than: "R400NKSU0AZD2"))
    }
}
