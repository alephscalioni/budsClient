import XCTest
@testable import BudsAutoSwitch

final class MacAudioActivityReaderTests: XCTestCase {
    func testDisappearingProcessRefreshesListAndDoesNotMissNewActivePlayer() throws {
        var enumerations = 0, reads: [UInt32] = []
        let activity = try MacAudioActivityReader.read(processes: {
            enumerations += 1
            return enumerations == 1 ? [40, 41] : [40, 42]
        }, sample: { id in
            reads.append(id)
            if id == 41 { return .init(output: nil, input: nil, application: "Old WebKit") }
            return .init(output: id == 42, input: false, application: "Safari")
        })
        XCTAssertEqual(enumerations, 2); XCTAssertEqual(reads, [40, 41, 40, 42])
        XCTAssertTrue(activity.output); XCTAssertFalse(activity.input)
        XCTAssertEqual(activity.applications, ["Safari"])
    }

    func testSurvivingUnknownInputCannotBecomeSilentOrTriggerUnboundedRetry() {
        var enumerations = 0
        XCTAssertThrowsError(try MacAudioActivityReader.read(processes: {
            enumerations += 1; return [42]
        }, sample: { _ in .init(output: false, input: nil, application: "Call") }))
        XCTAssertEqual(enumerations, 2)
    }

    func testIncompleteOldSnapshotCannotLeakActivityIntoItsReplacement() throws {
        var enumerations = 0
        let activity = try MacAudioActivityReader.read(processes: {
            enumerations += 1; return enumerations == 1 ? [1, 2] : [3]
        }, sample: { id in
            if id == 2 { return .init(output: nil, input: false, application: "Old helper") }
            return .init(output: id == 1, input: id == 1, application: "Player")
        })
        XCTAssertFalse(activity.output); XCTAssertFalse(activity.input)
        XCTAssertTrue(activity.applications.isEmpty); XCTAssertEqual(enumerations, 2)
    }
}
