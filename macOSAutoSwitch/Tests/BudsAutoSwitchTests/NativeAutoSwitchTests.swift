import XCTest
@testable import BudsAutoSwitch

final class NativeAutoSwitchTests: XCTestCase {
    private func state(_ state: SamsungMdePacket.MultipointStatus.State = .foreground,
                       _ stream: SamsungMdePacket.StreamType = .a2dp, reason: UInt8 = 0) -> SamsungMdePacket.MultipointStatus {
        .init(state: state, streamType: stream, reason: reason)
    }

    func testOnlyNewPlayEdgesCanRequestMac() {
        var policy = NativeSwitchEvidence()
        XCTAssertFalse(policy.playEdge(playing: true, revision: 5), "Already playing at enable is a baseline")
        XCTAssertFalse(policy.playEdge(playing: true, revision: 5))
        XCTAssertFalse(policy.playEdge(playing: false, revision: 5))
        XCTAssertTrue(policy.playEdge(playing: true, revision: 6))
        XCTAssertFalse(policy.playEdge(playing: true, revision: 6))
        XCTAssertTrue(policy.playEdge(playing: true, revision: 7), "Resume between polls")
    }

    func testWriteAndOldForegroundAreNotConfirmation() {
        var policy = NativeSwitchEvidence()
        XCTAssertFalse(policy.confirmsMac(after: 0, at: 1))
        policy.observe(state(), at: 1)
        let beforeRequest = policy.serial
        XCTAssertFalse(policy.confirmsMac(after: beforeRequest, at: 1))
        XCTAssertFalse(policy.observe(state(), at: 2), "Duplicate foreground cannot confirm a request")
        XCTAssertFalse(policy.confirmsMac(after: beforeRequest, at: 2))
        policy.observe(state(.background), at: 2)
        policy.observe(state(), at: 3)
        XCTAssertTrue(policy.confirmsMac(after: beforeRequest, at: 3))
        XCTAssertTrue(policy.confirmsMac(after: beforeRequest, at: 60), "Valid state lasts for this channel session")
        XCTAssertFalse(policy.confirmsMac(after: beforeRequest, at: 0), "No future-dated evidence")
    }

    func testIdempotentForegroundNeedsAPostRequestNotificationReceipt() {
        var policy = NativeSwitchEvidence()
        policy.observe(state(), at: 1)
        let serial = policy.serial, received = policy.notificationCount
        XCTAssertFalse(policy.confirmsMac(after: serial, afterNotification: received, at: 2))
        XCTAssertFalse(policy.observe(state(), at: 3), "Receipt is not a state transition")
        XCTAssertEqual(policy.serial, serial)
        XCTAssertFalse(policy.confirmsMac(after: serial, afterNotification: received, at: 2), "A future receipt cannot authorize routing")
        XCTAssertTrue(policy.confirmsMac(after: serial, afterNotification: received, at: 3))
        policy.observe(state(.background), at: 4)
        XCTAssertFalse(policy.confirmsMac(after: serial, afterNotification: received, at: 4))
        policy.resetVendorState()
        XCTAssertEqual(policy.notificationCount, 0)
        XCTAssertFalse(policy.confirmsMac(after: serial, afterNotification: received, at: 5))
    }

    func testBackgroundCannotConfirmMacButForegroundReason132IsNotARejection() {
        var policy = NativeSwitchEvidence()
        policy.observe(state(.background), at: 1)
        XCTAssertFalse(policy.confirmsMac(after: 0, at: 1))
        XCTAssertTrue(policy.remoteStream)
        policy.observe(state(.foreground, .a2dp, reason: 132), at: 2)
        XCTAssertTrue(policy.confirmsMac(after: 0, at: 2))
        XCTAssertFalse(policy.backgroundStreamRejected)
        policy.observe(state(.background, .a2dp, reason: 132), at: 3)
        XCTAssertFalse(policy.confirmsMac(after: 0, at: 3))
        XCTAssertTrue(policy.backgroundStreamRejected)
    }

    func testInitialBackground132IsNotARejectedTransitionWithoutPreviousState() {
        var policy = NativeSwitchEvidence()
        policy.observe(state(.background, .a2dp, reason: 132), at: 1)
        XCTAssertFalse(policy.backgroundStreamRejected)
        policy.observe(state(.background, .a2dp, reason: 132), at: 2)
        XCTAssertFalse(policy.backgroundStreamRejected, "An unchanged bootstrap is not a new transition")
        policy.observe(state(.foreground), at: 3)
        policy.observe(state(.background, .a2dp, reason: 132), at: 4)
        XCTAssertTrue(policy.backgroundStreamRejected)
        policy.resetVendorState()
        XCTAssertFalse(policy.backgroundStreamRejected)
    }

    func testCallsStayPriorityUntilExplicitNewStatus() {
        for flags: SamsungMdePacket.StreamType in [.hfp, .cisCall, [.a2dp, .hfp], [.cisMedia, .cisCall]] {
            var policy = NativeSwitchEvidence()
            policy.observe(state(.foreground, flags), at: 1)
            XCTAssertTrue(policy.callActive)
            XCTAssertFalse(policy.confirmsMac(after: 0, at: 1))
            XCTAssertTrue(policy.callActive, "Time passing cannot clear a call")
            XCTAssertTrue(policy.fresh(at: 100), "Time passing cannot invalidate channel state")
            policy.observe(state(.background, []), at: 101)
            XCTAssertFalse(policy.callActive)
        }
    }

    func testRemoteHUDRequiresBackgroundAndKnownStream() {
        var policy = NativeSwitchEvidence()
        XCTAssertFalse(policy.remoteStream)
        for flags: SamsungMdePacket.StreamType in [[], .autoSwitchRequest, .init(rawValue: 0x40)] {
            policy.observe(state(.background, flags), at: 1)
            XCTAssertFalse(policy.remoteStream)
        }
        var time: TimeInterval = 1
        for flags: SamsungMdePacket.StreamType in [.a2dp, .cisMedia, .hfp, .cisCall, .bis] {
            time += 1
            policy.observe(state(.foreground, flags), at: time)
            XCTAssertFalse(policy.remoteStream)
            time += 1
            policy.observe(state(.background, flags), at: time)
            XCTAssertTrue(policy.remoteStream)
        }
    }

    func testStreamAssemblesEverySplitAndConcatenatedFrames() throws {
        let packet = SamsungMdePacket.requestComputerSwitch()
        for split in 1..<packet.count {
            var stream = NativeBudsFrameStream()
            XCTAssertTrue(try stream.append(Data(packet.prefix(split)), at: 0).isEmpty)
            let frames = try stream.append(Data(packet.dropFirst(split)) + packet, at: 0.1)
            XCTAssertEqual(frames.count, 2)
            XCTAssertTrue(frames.allSatisfy { $0.command == 0x71 })
            XCTAssertTrue(stream.buffer.isEmpty)
        }
    }

    func testStreamRecoversAfterCorruptionAndGarbage() throws {
        let valid = SamsungMdePacket.playbackStatus(.playing)
        var corrupt = valid; corrupt[5] ^= 1
        var stream = NativeBudsFrameStream()
        let frames = try stream.append(Data([1, 2, 0xFC, 0, 0, 1]) + corrupt + valid, at: 1)
        XCTAssertEqual(frames, [SamsungMdePacket.decodeCompleteFrame(valid)!])
        XCTAssertTrue(stream.buffer.isEmpty)
    }

    func testStreamExpiresPartialDataInsteadOfCompletingStaleStatus() throws {
        let packet = SamsungMdePacket.outputDeviceState(.single)
        var stream = NativeBudsFrameStream()
        XCTAssertTrue(try stream.append(Data(packet.prefix(6)), at: 1).isEmpty)
        XCTAssertTrue(try stream.append(Data(packet.dropFirst(6)), at: 3).isEmpty)
        XCTAssertEqual(try stream.append(packet, at: 4).count, 1)
    }

    func testOversizedInputAndUnboundedGarbageFailExplicitly() throws {
        var stream = NativeBudsFrameStream()
        XCTAssertThrowsError(try stream.append(Data(repeating: 0, count: 4097), at: 0))
        for i in 0..<8 { XCTAssertTrue(try stream.append(Data(repeating: 0, count: 4096), at: Double(i)).isEmpty) }
        XCTAssertThrowsError(try stream.append(Data([0]), at: 9))
    }

    func testFragmentCannotBecomeStatus() throws {
        var packet = SamsungMdePacket.requestComputerSwitch()
        packet[2] |= 0x20 // Fragment flag is in the header, outside the CRC.
        var stream = NativeBudsFrameStream()
        XCTAssertTrue(try stream.append(packet, at: 0).isEmpty)
        XCTAssertTrue(stream.buffer.isEmpty)
    }

    @MainActor func testModelStartsDisabledAndRefusesMissingOwnershipWithoutIO() {
        let model = NativeAutoSwitchModel(environment: NativeControllerHarness().environment())
        XCTAssertFalse(model.enabled)
        XCTAssertFalse(model.ready)
        XCTAssertEqual(model.transport, "native")
        XCTAssertTrue(model.phones.isEmpty)
        XCTAssertTrue(model.selectedPhone.isEmpty)
        model.start(transportGranted: false)
        XCTAssertFalse(model.enabled)
        XCTAssertFalse(model.busy)
        XCTAssertNotNil(model.error)
        model.stop()
        XCTAssertFalse(model.busy)
    }

    @MainActor func testNoAutomaticStartAfterConfigurationAndClosedSendThrows() {
        let model = NativeAutoSwitchModel(environment: NativeControllerHarness().environment())
        model.configurationChanged()
        XCTAssertFalse(model.enabled)
        model.start(transportGranted: true) // No validated selection, hence no radio access.
        XCTAssertFalse(model.enabled)
        let transport = NativeBudsTransport()
        XCTAssertThrowsError(try transport.send(SamsungMdePacket.requestComputerSwitch()))
        transport.close()
        XCTAssertFalse(transport.isOpen)
    }

    @MainActor func testCancelledOpenExitsBeforePairedDeviceLookup() async {
        let transport = NativeBudsTransport()
        let task = Task { @MainActor in try await transport.open(address: "00:00:00:00:00:00") }
        // This actor cannot run the task body until the test suspends below.
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled open must throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(transport.isOpen)
        transport.rfcommChannelClosed(nil)
        transport.close()
    }
}
