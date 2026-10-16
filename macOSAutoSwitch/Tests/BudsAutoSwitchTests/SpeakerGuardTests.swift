import XCTest
@testable import BudsAutoSwitch

private final class MemoryGuardJournal: SpeakerGuardJournal {
    var entry: SpeakerGuardRecord?
    var failWrite = false
    var failRemove = false
    var locked = false
    func withLock(_ action: () throws -> Void) throws {
        XCTAssertFalse(locked)
        locked = true
        defer { locked = false }
        try action()
    }
    func read() throws -> SpeakerGuardRecord? { XCTAssertTrue(locked); return entry }
    func write(_ record: SpeakerGuardRecord) throws {
        XCTAssertTrue(locked)
        if failWrite { throw BridgeError.message("journal write failed") }
        entry = record
    }
    func remove() throws {
        XCTAssertTrue(locked)
        if failRemove { throw BridgeError.message("journal removal failed") }
        entry = nil
    }
}

private final class GuardFixture {
    let journal = MemoryGuardJournal()
    var currentMute: UInt32 = 0
    var resolvedDevice: UInt32 = 42
    var livePIDs: Set<Int32> = [100]
    var writes: [(UInt32, UInt32)] = []
    var launches = 0
    var capabilityFailure = false
    var resolutionFailure = false
    var writeFailure = false
    var launchFailure = false
    var applyBeforeWriteFailure = false

    var environment: SpeakerGuardEnvironment {
        SpeakerGuardEnvironment(journal: journal, pid: 100,
            isAlive: { self.livePIDs.contains($0) },
            uid: { _ in "stable-speaker-uid" },
            resolve: { uid in
                XCTAssertEqual(uid, "stable-speaker-uid")
                if self.resolutionFailure { throw BridgeError.message("device unavailable") }
                return self.resolvedDevice
            }, mute: { _ in
                if self.capabilityFailure { throw BridgeError.message("no settable master mute") }
                return self.currentMute
            }, setMute: { device, value in
                // Recovery must already be durable, and the watchdog started, before mute.
                XCTAssertTrue(self.journal.locked)
                XCTAssertNotNil(self.journal.entry)
                self.writes.append((device, value))
                if self.writeFailure {
                    if self.applyBeforeWriteFailure { self.currentMute = value }
                    throw BridgeError.message("mute confirmation timed out")
                }
                self.currentMute = value
            }, startWatchdog: { record in
                XCTAssertTrue(self.journal.locked)
                XCTAssertEqual(self.journal.entry, record)
                XCTAssertEqual(self.currentMute, record.originalMute)
                self.launches += 1
                if self.launchFailure { throw BridgeError.message("launch failed") }
            })
    }

    func abandoned(original: UInt32 = 0, owner: Int32 = 200) -> SpeakerGuardRecord {
        SpeakerGuardRecord(deviceUID: "stable-speaker-uid", originalMute: original,
                           ownerPID: owner, token: UUID().uuidString)
    }
}

@MainActor final class SpeakerGuardTests: XCTestCase {
    func testArmMutesBeforeReturningAndRestoreResolvesStableUID() async throws {
        let fixture = GuardFixture()
        let guardObject = SpeakerGuard(environment: fixture.environment)
        XCTAssertFalse(guardObject.isArmed)
        XCTAssertNil(guardObject.armedDevice)
        try await guardObject.arm(42)
        XCTAssertTrue(guardObject.isArmed)
        XCTAssertEqual(guardObject.armedDevice, 42)
        XCTAssertEqual(fixture.currentMute, 1)
        XCTAssertEqual(fixture.launches, 1)
        try guardObject.verify()
        try await guardObject.arm(42)
        XCTAssertEqual(fixture.writes.count, 1)
        fixture.resolvedDevice = 99 // HAL IDs can change; never persist or restore by the old ID.
        try guardObject.verify()
        XCTAssertEqual(guardObject.armedDevice, 99, "Route comparisons must use the current HAL ID for the stable UID")
        try await guardObject.restore()
        XCTAssertEqual(fixture.currentMute, 0)
        XCTAssertEqual(fixture.writes.last?.0, 99)
        XCTAssertNil(fixture.journal.entry)
        XCTAssertFalse(guardObject.isArmed)
        XCTAssertNil(guardObject.armedDevice)
        try await guardObject.restore()
        try guardObject.verify()
        XCTAssertEqual(fixture.writes.count, 2)
    }

    func testOriginalMuteOneIsPreservedWithoutWrites() async throws {
        let fixture = GuardFixture()
        fixture.currentMute = 1
        let guardObject = SpeakerGuard(environment: fixture.environment)
        try await guardObject.arm(42)
        XCTAssertEqual(fixture.journal.entry?.originalMute, 1)
        try await guardObject.restore()
        XCTAssertEqual(fixture.currentMute, 1)
        XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertNil(fixture.journal.entry)
    }

    func testManualUnmuteThrowsAndNeverRemutesEvenIfOriginalWasMuted() async throws {
        for original: UInt32 in [0, 1] {
            let fixture = GuardFixture()
            fixture.currentMute = original
            let guardObject = SpeakerGuard(environment: fixture.environment)
            try await guardObject.arm(42)
            let writeCount = fixture.writes.count
            fixture.currentMute = 0
            XCTAssertThrowsError(try guardObject.verify())
            XCTAssertEqual(fixture.journal.entry?.manuallyUnmuted, true)
            do { try await guardObject.arm(42); XCTFail("Must not rearm after manual unmute") } catch {}
            try await guardObject.restore()
            XCTAssertEqual(fixture.currentMute, 0)
            XCTAssertEqual(fixture.writes.count, writeCount)
            XCTAssertNil(fixture.journal.entry)
        }
    }

    func testManualUnmuteFollowedByManualMuteRemainsUserOwned() async throws {
        let fixture = GuardFixture()
        let state = SpeakerGuardState(environment: fixture.environment)
        try state.arm(42)
        fixture.currentMute = 0
        XCTAssertThrowsError(try state.verify())
        fixture.currentMute = 1
        XCTAssertThrowsError(try state.verify())
        try state.restore()
        XCTAssertEqual(fixture.currentMute, 1)
        XCTAssertEqual(fixture.writes.count, 1)
    }

    func testRestoreRespectsUnmuteWithoutAnInterveningVerify() throws {
        let fixture = GuardFixture()
        let state = SpeakerGuardState(environment: fixture.environment)
        try state.arm(42)
        fixture.currentMute = 0
        try state.restore()
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertNil(fixture.journal.entry)
    }

    func testUnavailableMuteCannotArmOrLaunchWatchdog() throws {
        let fixture = GuardFixture()
        fixture.capabilityFailure = true
        let state = SpeakerGuardState(environment: fixture.environment)
        XCTAssertThrowsError(try state.arm(42))
        XCTAssertNil(state.record)
        XCTAssertNil(fixture.journal.entry)
        XCTAssertEqual(fixture.launches, 0)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testJournalWriteFailureCannotMute() throws {
        let fixture = GuardFixture()
        fixture.journal.failWrite = true
        let state = SpeakerGuardState(environment: fixture.environment)
        XCTAssertThrowsError(try state.arm(42))
        XCTAssertNil(state.record)
        XCTAssertEqual(fixture.launches, 0)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testWatchdogLaunchFailureCannotMuteAndCleansJournal() throws {
        let fixture = GuardFixture()
        fixture.launchFailure = true
        let state = SpeakerGuardState(environment: fixture.environment)
        XCTAssertThrowsError(try state.arm(42))
        XCTAssertNil(state.record)
        XCTAssertNil(fixture.journal.entry)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testLaunchAndCleanupFailureRetainsRecoveryAndReportsBoth() throws {
        let fixture = GuardFixture()
        fixture.launchFailure = true
        fixture.journal.failRemove = true
        let state = SpeakerGuardState(environment: fixture.environment)
        XCTAssertThrowsError(try state.arm(42)) { error in
            XCTAssertTrue(error.localizedDescription.contains("launch failed"))
            XCTAssertTrue(error.localizedDescription.contains("journal removal failed"))
        }
        XCTAssertNotNil(state.record)
        XCTAssertNotNil(fixture.journal.entry)
        XCTAssertTrue(fixture.writes.isEmpty)
        fixture.journal.failRemove = false
        try state.restore()
        XCTAssertNil(state.record)
    }

    func testUnconfirmedArmRetainsRecoveryAndCanRestore() throws {
        let fixture = GuardFixture()
        fixture.writeFailure = true
        fixture.applyBeforeWriteFailure = true
        let state = SpeakerGuardState(environment: fixture.environment)
        XCTAssertThrowsError(try state.arm(42))
        XCTAssertEqual(fixture.currentMute, 1)
        XCTAssertNotNil(state.record)
        XCTAssertNotNil(fixture.journal.entry)
        XCTAssertEqual(fixture.launches, 1)
        fixture.writeFailure = false
        try state.restore()
        XCTAssertEqual(fixture.currentMute, 0)
        XCTAssertNil(state.record)
    }

    func testFailedRestoreKeepsRecoveryForRetry() throws {
        let fixture = GuardFixture()
        let state = SpeakerGuardState(environment: fixture.environment)
        try state.arm(42)
        fixture.writeFailure = true
        XCTAssertThrowsError(try state.restore())
        XCTAssertNotNil(state.record)
        XCTAssertNotNil(fixture.journal.entry)
        XCTAssertEqual(fixture.currentMute, 1)
        fixture.writeFailure = false
        try state.restore()
        XCTAssertEqual(fixture.currentMute, 0)
        XCTAssertNil(state.record)
    }

    func testJournalRemovalFailureKeepsStateAfterAudioRestoration() throws {
        let fixture = GuardFixture()
        let state = SpeakerGuardState(environment: fixture.environment)
        try state.arm(42)
        fixture.journal.failRemove = true
        XCTAssertThrowsError(try state.restore())
        XCTAssertEqual(fixture.currentMute, 0)
        XCTAssertNotNil(state.record)
        XCTAssertNotNil(fixture.journal.entry)
        fixture.journal.failRemove = false
        try state.restore()
        XCTAssertEqual(fixture.writes.count, 2)
        XCTAssertNil(state.record)
    }

    func testLiveOtherOwnerBlocksArmAndStartupRecovery() throws {
        let fixture = GuardFixture()
        let entry = fixture.abandoned()
        fixture.journal.entry = entry
        fixture.livePIDs.insert(entry.ownerPID)
        fixture.currentMute = 1
        try SpeakerGuardState.recoverAbandoned(environment: fixture.environment)
        XCTAssertEqual(fixture.journal.entry, entry)
        let state = SpeakerGuardState(environment: fixture.environment)
        XCTAssertThrowsError(try state.arm(42))
        XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertEqual(fixture.launches, 0)
    }

    func testDeadOwnerRecoveredBeforeNewArm() throws {
        let fixture = GuardFixture()
        fixture.journal.entry = fixture.abandoned()
        fixture.currentMute = 1
        let state = SpeakerGuardState(environment: fixture.environment)
        try state.arm(42)
        XCTAssertEqual(fixture.writes.map { $0.1 }, [0, 1])
        XCTAssertEqual(fixture.journal.entry?.ownerPID, 100)
        XCTAssertEqual(fixture.journal.entry?.originalMute, 0)
        try state.restore()
    }

    func testOwnershipReplacementBlocksVerifyAndRestoreWithoutMutatingAudio() throws {
        let fixture = GuardFixture()
        let state = SpeakerGuardState(environment: fixture.environment)
        try state.arm(42)
        let replacement = fixture.abandoned(owner: 300)
        fixture.journal.entry = replacement
        XCTAssertThrowsError(try state.verify())
        XCTAssertThrowsError(try state.restore())
        XCTAssertEqual(fixture.journal.entry, replacement)
        XCTAssertEqual(fixture.currentMute, 1)
        XCTAssertEqual(fixture.writes.count, 1)
        XCTAssertNotNil(state.record)
    }

    func testDifferentDeviceCannotReplaceActiveGuard() throws {
        let fixture = GuardFixture()
        let state = SpeakerGuardState(environment: fixture.environment)
        try state.arm(42)
        XCTAssertThrowsError(try state.arm(43))
        XCTAssertEqual(state.device, 42)
        XCTAssertEqual(fixture.launches, 1)
    }

    func testWatchdogWaitsForOwnerDeathThenRestores() throws {
        let fixture = GuardFixture()
        let entry = fixture.abandoned()
        fixture.journal.entry = entry
        fixture.currentMute = 1
        fixture.livePIDs.insert(entry.ownerPID)
        XCTAssertTrue(try SpeakerGuardState.watchdogTick(environment: fixture.environment, token: entry.token, owner: entry.ownerPID))
        XCTAssertTrue(fixture.writes.isEmpty)
        fixture.livePIDs.remove(entry.ownerPID)
        XCTAssertFalse(try SpeakerGuardState.watchdogTick(environment: fixture.environment, token: entry.token, owner: entry.ownerPID))
        XCTAssertEqual(fixture.currentMute, 0)
        XCTAssertNil(fixture.journal.entry)
    }

    func testWatchdogExitsWhenJournalRemovedOrReplacedOrOwnerMismatches() throws {
        let fixture = GuardFixture()
        let entry = fixture.abandoned()
        XCTAssertFalse(try SpeakerGuardState.watchdogTick(environment: fixture.environment, token: entry.token, owner: entry.ownerPID))
        fixture.journal.entry = fixture.abandoned()
        XCTAssertFalse(try SpeakerGuardState.watchdogTick(environment: fixture.environment, token: entry.token, owner: entry.ownerPID))
        fixture.journal.entry = entry
        XCTAssertFalse(try SpeakerGuardState.watchdogTick(environment: fixture.environment, token: entry.token, owner: 999))
        XCTAssertEqual(fixture.journal.entry, entry)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testRecoveryAndWatchdogPreserveOriginalMuteAndManualUnmute() throws {
        for original: UInt32 in [0, 1] {
            for current: UInt32 in [0, 1] {
                for watchdog in [false, true] {
                    let fixture = GuardFixture()
                    let entry = fixture.abandoned(original: original)
                    fixture.journal.entry = entry
                    fixture.currentMute = current
                    if watchdog {
                        XCTAssertFalse(try SpeakerGuardState.watchdogTick(environment: fixture.environment, token: entry.token, owner: entry.ownerPID))
                    } else {
                        try SpeakerGuardState.recoverAbandoned(environment: fixture.environment)
                    }
                    XCTAssertEqual(fixture.currentMute, current == 0 ? 0 : original)
                    XCTAssertEqual(fixture.writes.count, current == 1 && original == 0 ? 1 : 0)
                    XCTAssertNil(fixture.journal.entry)
                }
            }
        }
    }

    func testWatchdogRecoveryFailureIsExplicitAndKeepsJournal() throws {
        let fixture = GuardFixture()
        let entry = fixture.abandoned()
        fixture.journal.entry = entry
        fixture.currentMute = 1
        fixture.writeFailure = true
        XCTAssertThrowsError(try SpeakerGuardState.watchdogTick(environment: fixture.environment, token: entry.token, owner: entry.ownerPID))
        XCTAssertEqual(fixture.journal.entry, entry)
        XCTAssertEqual(fixture.currentMute, 1)
        fixture.writeFailure = false
        fixture.resolutionFailure = true
        XCTAssertThrowsError(try SpeakerGuardState.recoverAbandoned(environment: fixture.environment))
        XCTAssertEqual(fixture.journal.entry, entry)
    }

    func testRecordedManualOverrideIsRespectedByAbandonedRecovery() throws {
        let fixture = GuardFixture()
        var entry = fixture.abandoned()
        entry.manuallyUnmuted = true
        fixture.journal.entry = entry
        fixture.currentMute = 1
        try SpeakerGuardState.recoverAbandoned(environment: fixture.environment)
        XCTAssertEqual(fixture.currentMute, 1)
        XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertNil(fixture.journal.entry)
    }

    func testFileJournalHasPrivatePermissionsAndOnlyStableIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SpeakerGuardFileJournal(directory: directory)
        let entry = GuardFixture().abandoned()
        try journal.withLock {
            XCTAssertNil(try journal.read())
            try journal.write(entry)
            XCTAssertEqual(try journal.read(), entry)
            let file = directory.appendingPathComponent("recovery.json")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            XCTAssertEqual(Set(json.keys), Set(["deviceUID", "originalMute", "ownerPID", "token", "manuallyUnmuted"]))
            try journal.remove()
            XCTAssertNil(try journal.read())
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testMalformedJournalIsNotSilentlyDeleted() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = SpeakerGuardFileJournal(directory: directory)
        try journal.withLock {
            let file = directory.appendingPathComponent("recovery.json")
            try Data("invalid json".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            XCTAssertThrowsError(try journal.read())
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        }
    }
}
