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
}
