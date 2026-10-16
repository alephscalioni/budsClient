import XCTest
@testable import BudsAutoSwitch

final class NativeSamsungPeerPolicyTests: XCTestCase {
    func testVerifiedInputRequiresRosterMemberAndValidNonPlaceholderAddress() throws {
        let a = try SamsungPeerAddress(bytes: Data([2, 0, 0, 0, 0, 1]))
        let b = try SamsungPeerAddress(bytes: Data([2, 0, 0, 0, 0, 2]))
        let roster = try SamsungPeerRoster(revision: 1, members: [a])
        XCTAssertThrowsError(try NativeSamsungPeerVerifiedAddress(hostVerifiedClassicPhone: b, roster: roster))
        for bytes in [Data(count: 6), Data(repeating: 255, count: 6)] {
            let address = try SamsungPeerAddress(bytes: bytes)
            let bad = try SamsungPeerRoster(revision: 1, members: [address])
            XCTAssertThrowsError(try NativeSamsungPeerVerifiedAddress(hostVerifiedClassicPhone: address, roster: bad))
        }
    }
    func testOpeningRejectsInvalidBudgetAndRecordChannel() throws {
        for budget in [0, -1, .infinity, .nan, 121] {
            XCTAssertThrowsError(try NativeSamsungPeerOpeningPolicy(now: 1, budget: budget))
        }
        for id: UInt8? in [nil, 0, 31, 255] {
            var policy = try NativeSamsungPeerOpeningPolicy(now: 1, budget: 10)
            XCTAssertThrowsError(try policy.discovered(recordChannel: id, now: 2))
        }
    }
    func testOpeningDoesNotExtendDeadlineAndRejectsInvalidMTU() throws {
        var policy = try NativeSamsungPeerOpeningPolicy(now: 1, budget: 10)
        try policy.connected(now: 5)
        XCTAssertEqual(try policy.discovered(recordChannel: 30, now: 9), 30)
        XCTAssertEqual(policy.deadline, 11)
        XCTAssertThrowsError(try policy.opened(mtu: 5, now: 11))
        XCTAssertThrowsError(try policy.opened(mtu: 0, now: 10))
        XCTAssertThrowsError(try policy.opened(mtu: 65536, now: 10))
        try policy.opened(mtu: 1, now: 10)
        XCTAssertEqual(policy.phase, .openUntrusted)
    }
    func testWriteExactIDAndTotalDeadlineIncludingFinalChunk() throws {
        var p = try NativeSamsungPeerWritePolicy(count: 5, mtu: 3, now: 1, budget: 5)
        XCTAssertEqual(try p.next(id: 5, now: 1), 0..<3)
        XCTAssertThrowsError(try p.next(id: 6, now: 2))
        XCTAssertFalse(try p.complete(id: 4, success: true, bytesWritten: 3, now: 2))
        XCTAssertTrue(try p.complete(id: 5, success: true, bytesWritten: 3, now: 4))
        XCTAssertEqual(try p.next(id: 6, now: 5), 3..<5)
        XCTAssertThrowsError(try p.complete(id: 6, success: true, bytesWritten: 2, now: 6))
        XCTAssertFalse(p.finished)
    }
    @MainActor func testLeaseIDCannotReleaseNewSessionAndDifferentPeersAreIndependent() throws {
        let a = try SamsungPeerAddress(bytes: Data([2, 0, 0, 0, 0, 1]))
        let b = try SamsungPeerAddress(bytes: Data([2, 0, 0, 0, 0, 2]))
        let roster = try SamsungPeerRoster(revision: 1, members: [a, b])
        let p = try NativeSamsungPeerVerifiedAddress(hostVerifiedClassicPhone: a, roster: roster)
        let q = try NativeSamsungPeerVerifiedAddress(hostVerifiedClassicPhone: b, roster: roster)
        let d = NativeSamsungPeerOperationDrain(); let old = UUID(); let new = UUID()
        try d.acquire(p, id: old, owner: NSObject()); try d.acquire(q, id: UUID(), owner: NSObject())
        XCTAssertEqual(d.count, 2); d.release(p, id: old)
        try d.acquire(p, id: new, owner: NSObject()); d.release(p, id: old)
        XCTAssertEqual(d.count, 2); XCTAssertThrowsError(try d.acquire(p, id: UUID(), owner: NSObject()))
        d.release(p, id: new); XCTAssertEqual(d.count, 1)
    }
}
