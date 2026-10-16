import XCTest
import CoreAudio
@testable import BudsAutoSwitch

final class NativeBudsAudioPresenceTests: XCTestCase {
    private let address = "AA:BB:CC:DD:EE:01"
    private typealias Presence = NativeBudsAudioPresence
    private func endpoint(uid: String = "AA-BB-CC-DD-EE-01:input", transport: UInt32 = kAudioDeviceTransportTypeBluetooth,
                          alive: Bool = true, input: Bool = true, output: Bool = false, running: Bool = true) -> Presence.Endpoint {
        .init(uid: uid, transport: transport, alive: alive, input: input, output: output, running: running)
    }
    private func environment(_ endpoint: Presence.Endpoint?, defaultInput: AudioObjectID? = 11,
                             defaultOutput: AudioObjectID? = 22, devices: [AudioObjectID]? = [11, 22]) -> Presence.Environment {
        .init(devices: { devices }, defaultInput: { defaultInput }, defaultOutput: { defaultOutput }, endpoint: { id in
            id == 11 ? endpoint : .init(uid: "BuiltInSpeakerDevice", transport: kAudioDeviceTransportTypeBuiltIn,
                alive: true, input: false, output: true, running: false)
        })
    }
    func testHFPInputRemainsConnectionEvidenceWithUnrelatedSystemOutput() {
        XCTAssertEqual(Presence.read(address: address, environment: environment(endpoint())), true)
        XCTAssertTrue(NativeBudsPanelConnection.connected(readFailed: false, physicalLink: true, audioPresent: true,
            deviceState: false, existingSettingsRoute: false))
    }
    func testAppSpecificRunningBudsEndpointDoesNotRequireSystemDefault() {
        let live = endpoint(uid: "AA-BB-CC-DD-EE-01:output", input: false, output: true)
        XCTAssertEqual(Presence.read(address: address, environment: environment(live, defaultInput: 22)), true)
        let idle = endpoint(uid: live.uid, input: false, output: true, running: false)
        XCTAssertEqual(Presence.read(address: address, environment: environment(idle, defaultInput: 22)), false)
    }
    func testExactSelectedBluetoothIdentityLivenessAndStreamRequired() {
        let wrong = [endpoint(uid: "11-22-33-44-55-66:input"), endpoint(uid: "prefix-AA-BB-CC-DD-EE-01:input"),
            endpoint(uid: "AA:BB-CC:DD:EE:01:input"), endpoint(uid: "Galaxy Buds3 Pro"),
            endpoint(transport: kAudioDeviceTransportTypeBuiltIn), endpoint(alive: false),
            endpoint(input: false, output: false), endpoint(uid: "AA-BB-CC-DD-EE-01:output")]
        for candidate in wrong {
            XCTAssertEqual(Presence.read(address: address, environment: environment(candidate)), false, candidate.uid)
        }
        XCTAssertNil(Presence.read(address: "", environment: environment(endpoint())))
    }
    func testUnavailableHALDoesNotInventDisconnectionOrConnection() {
        XCTAssertNil(Presence.read(address: address, environment: environment(nil)))
        XCTAssertNil(Presence.read(address: address, environment: environment(nil, defaultInput: nil, defaultOutput: nil, devices: nil)))
        XCTAssertFalse(NativeBudsPanelConnection.connected(readFailed: false, physicalLink: nil, audioPresent: nil,
            deviceState: false, existingSettingsRoute: false))
    }
    func testExplicitPhysicalLossAndSnapshotFailureStillHideStaleEvidence() {
        let cases: [(Bool, Bool?)] = [(false, false), (true, true), (true, nil)]
        for (failed, physical) in cases {
            XCTAssertFalse(NativeBudsPanelConnection.connected(readFailed: failed, physicalLink: physical, audioPresent: true,
                deviceState: true, existingSettingsRoute: true))
        }
        XCTAssertFalse(NativeBudsPanelConnection.connected(readFailed: false, physicalLink: nil, audioPresent: true,
            deviceState: false, existingSettingsRoute: false))
    }
}
