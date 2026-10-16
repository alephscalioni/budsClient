import XCTest
@testable import BudsAutoSwitch

final class SamsungAccountSetupPolicyTests: XCTestCase {
    func testEveryPrerequisiteAndNoBlockerRequired() {
        for bits in 0..<32 {
            let authenticated = bits & 1 != 0, registered = bits & 2 != 0
            let certificate = bits & 4 != 0, roster = bits & 8 != 0, blocked = bits & 16 != 0
            XCTAssertEqual(SamsungAccountSetupPolicy.isReady(authenticated: authenticated, registered: registered,
                certificateReady: certificate, rosterConfirmed: roster, blocked: blocked), bits == 15,
                "Incorrect readiness for state \(bits)")
        }
    }
}
