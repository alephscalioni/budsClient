import XCTest
@testable import BudsAutoSwitch

final class CommandRunnerTests: XCTestCase {
    func testArgumentsArePassedLiterallyWithoutAShell() async throws {
        let literal = "a path with spaces; $(not-a-command) 'quoted'"
        let result = try await runCommand("/usr/bin/printf", ["%s", literal])
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(result.output, literal)
    }
    func testDeadlineKillsAProcessThatIgnoresTermination() async throws {
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await runCommand("/bin/sh", ["-c", "trap '' TERM; while :; do :; done"], timeout: 0.2)
        XCTAssertNotEqual(result.code, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 5)
    }
}
