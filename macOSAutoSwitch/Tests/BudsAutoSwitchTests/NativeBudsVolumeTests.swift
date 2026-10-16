import XCTest
import CoreAudio
@testable import BudsAutoSwitch

/// All HAL and ownership effects are fake. No live environment is constructed.
@MainActor private final class VolumeHarness {
    typealias Property = NativeBudsVolumeEnvironment.Property
    typealias Endpoint = NativeBudsVolumeEnvironment.Endpoint
    let address = "AA:BB:CC:DD:EE:FF"
    var selected = "AA:BB:CC:DD:EE:FF"
    var allowed = true
    var output: AudioObjectID = 41
    var endpoints: [AudioObjectID: Endpoint] = [
        41: Endpoint(uid: "AA-BB-CC-DD-EE-FF:output", transport: kAudioDeviceTransportTypeBluetooth, alive: true, output: true),
        42: Endpoint(uid: "BuiltInSpeakerDevice", transport: kAudioDeviceTransportTypeBuiltIn, alive: true, output: true),
        43: Endpoint(uid: "11-22-33-44-55-66:output", transport: kAudioDeviceTransportTypeBluetooth, alive: true, output: true)
    ]
    var properties: [Property: Bool] = [.virtualMain: true]
    var scalar: Float32 = 0.25
    var writes: [(AudioObjectID, Property, Float32)] = []
    var queried: [Property] = []
    var defaultReads = 0
    var endpointReads = 0
    var permissionReads = 0
    var reads = 0
    var writeFails = false
    var readFails = false
    var applyWrite = true
    var onRead: (() -> Void)?
    var onWritable: (() -> Void)?
    var onEndpoint: (() -> Void)?
    var afterWrite: (() -> Void)?

    lazy var controller = NativeBudsVolume(environment: .init(defaultOutput: {
        self.defaultReads += 1
        return self.output
    }, endpoint: { id in
        self.endpointReads += 1
        self.onEndpoint?()
        guard let endpoint = self.endpoints[id] else {
            throw NativeBudsVolumeEnvironment.Failure(message: "Dispositivo ausente.")
        }
        return endpoint
    }, writable: { id, property in
        XCTAssertEqual(id, 41)
        self.queried.append(property)
        self.onWritable?()
        return self.properties[property]
    }, read: { id, _ in
        XCTAssertEqual(id, 41)
        self.reads += 1
        if self.readFails { throw NativeBudsVolumeEnvironment.Failure(message: "Falha de leitura simulada.") }
        let value = self.scalar
        self.onRead?()
        return value
    }, write: { id, property, scalar in
        self.writes.append((id, property, scalar))
        if self.writeFails { throw NativeBudsVolumeEnvironment.Failure(message: "Falha de escrita simulada.") }
        if self.applyWrite { self.scalar = scalar }
        self.afterWrite?()
    }), permission: {
        self.permissionReads += 1
        return .init(selectedAddress: self.selected, canSet: self.allowed)
    })
}

final class NativeBudsVolumeTests: XCTestCase {
    /// Synchronous XCTest methods run on the main thread; the production
    /// controller shares the native integration's main actor isolation.
    private func check(_ body: @MainActor (VolumeHarness) throws -> Void) rethrows {
        try MainActor.assumeIsolated { try body(VolumeHarness()) }
    }

    func testWrongDefaultOutputNeverReadsOrWritesItsVolume() {
        check { h in
            for id: AudioObjectID in [42, 43, 0] {
                h.output = id
                let state = h.controller.snapshot
                XCTAssertEqual(state["available"] as? Bool, false)
                XCTAssertEqual(state["can_set"] as? Bool, false)
                XCTAssertTrue(state["level"] is NSNull)
                h.controller.perform(level: 50)
                XCTAssertNotNil(h.controller.error)
            }
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertEqual(h.reads, 0)
            XCTAssertTrue(h.queried.isEmpty)
        }
    }

    func testExactBluetoothUIDRequiredInsteadOfSubstringOrName() {
        check { h in
            for uid in ["Galaxy Buds3 Pro", "prefix-AA-BB-CC-DD-EE-FF:output", "AA-BB-CC-DD-EE-FF:output-extra",
                        "AA-BB-CC-DD-EE-FF:input", "AA-BB-CC-DD-EE-FF00", "AA:BB-CC:DD:EE:FF:output"] {
                h.endpoints[41]?.uid = uid
                h.controller.perform(level: 40)
                XCTAssertNotNil(h.controller.error, uid)
            }
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertEqual(h.reads, 0)
        }
    }

    func testSupportedExactUIDFormsAndBluetoothTransports() {
        check { h in
            for uid in ["aa-bb-cc-dd-ee-ff:output", "AA:BB:CC:DD:EE:FF:output", "aabbccddeeff", "AA-BB-CC-DD-EE-FF"] {
                for transport in [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE] {
                    h.endpoints[41]?.uid = uid
                    h.endpoints[41]?.transport = transport
                    XCTAssertEqual(h.controller.snapshot["can_set"] as? Bool, true, uid)
                }
            }
            XCTAssertTrue(h.writes.isEmpty)
        }
    }

    func testMatchingUIDStillRequiresBluetoothAliveOutputEndpoint() {
        check { h in
            let good = h.endpoints[41]!
            var invalid = good; invalid.transport = kAudioDeviceTransportTypeBuiltIn
            var dead = good; dead.alive = false
            var inputOnly = good; inputOnly.output = false
            for endpoint in [invalid, dead, inputOnly] {
                h.endpoints[41] = endpoint
                h.controller.perform(level: 35)
                XCTAssertNotNil(h.controller.error)
                XCTAssertTrue(h.controller.snapshot["level"] is NSNull)
            }
            XCTAssertTrue(h.writes.isEmpty)
        }
    }

    func testMissingMainPropertiesAreUnavailableWithoutChannelWrites() {
        check { h in
            h.properties = [:]
            let state = h.controller.snapshot
            XCTAssertEqual(state["available"] as? Bool, false)
            XCTAssertEqual(state["can_set"] as? Bool, false)
            XCTAssertTrue(state["level"] is NSNull)
            h.controller.perform(level: 70)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
            XCTAssertEqual(h.reads, 0)
        }
    }

    func testReadOnlyPropertyExposesMeasuredLevelButRejectsWrite() {
        check { h in
            h.properties = [.virtualMain: false, .mainScalar: true]
            let state = h.controller.snapshot
            XCTAssertEqual(state["available"] as? Bool, true)
            XCTAssertEqual(state["can_set"] as? Bool, false)
            XCTAssertEqual(state["level"] as? Double, 25)
            h.controller.perform(level: 70)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
            XCTAssertFalse(h.queried.contains(.mainScalar), "Do not bypass a present read-only virtual main")
        }
    }

    func testMainScalarFallbackOnlyWhenVirtualMainAbsent() {
        check { h in
            h.properties = [.mainScalar: true]
            h.controller.perform(level: 62.5)
            XCTAssertNil(h.controller.error)
            XCTAssertEqual(h.writes.count, 1)
            XCTAssertEqual(h.writes.first?.0, 41)
            XCTAssertEqual(h.writes.first?.1, .mainScalar)
            XCTAssertEqual(h.controller.snapshot["level"] as? Double, 62.5)
            h.properties = [.mainScalar: false]
            h.controller.perform(level: 30)
            XCTAssertEqual(h.writes.count, 1)
            XCTAssertEqual(h.controller.snapshot["can_set"] as? Bool, false)
        }
    }

    func testVirtualMainPreferredAndUsesOutputMainElement() {
        check { h in
            h.properties = [.virtualMain: true, .mainScalar: true]
            h.controller.perform(level: 50)
            XCTAssertNil(h.controller.error)
            XCTAssertEqual(h.writes.count, 1)
            XCTAssertEqual(h.writes.first?.1, .virtualMain)
            XCTAssertFalse(h.queried.contains(.mainScalar))
            for property in VolumeHarness.Property.allCases {
                XCTAssertEqual(property.address.mScope, kAudioDevicePropertyScopeOutput)
                XCTAssertEqual(property.address.mElement, kAudioObjectPropertyElementMain)
            }
        }
    }

    func testInvalidBooleanAndNonfiniteLevelsRejectedBeforeAnyEffects() throws {
        try check { h in
            let json = try JSONSerialization.jsonObject(with: Data("{\"level\":true}".utf8)) as! [String: Any]
            let invalid: [Any?] = [nil, NSNull(), "50", json["level"], NSNumber(value: false),
                NSNumber(value: -0.01), NSNumber(value: 100.01), NSNumber(value: Double.nan),
                NSNumber(value: Double.infinity), NSNumber(value: -Double.infinity)]
            for level in invalid {
                h.controller.perform(level: level)
                XCTAssertNotNil(h.controller.error)
            }
            XCTAssertEqual(h.permissionReads, 0)
            XCTAssertEqual(h.defaultReads, 0)
            XCTAssertTrue(h.writes.isEmpty)
        }
    }

    func testNumericJSONEndpointsAndFractionalLevelWriteAndReadBack() throws {
        try check { h in
            for level in [0.0, 37.25, 100.0] {
                let request = try JSONSerialization.jsonObject(with: Data("{\"level\":\(level)}".utf8)) as! [String: Any]
                h.controller.perform(level: request["level"])
                XCTAssertNil(h.controller.error)
                XCTAssertEqual(h.writes.last?.0, 41)
                XCTAssertEqual(h.writes.last?.1, .virtualMain)
                XCTAssertEqual(try XCTUnwrap(h.controller.snapshot["level"] as? Double), level, accuracy: 0.0001)
            }
            XCTAssertEqual(h.writes.count, 3)
        }
    }

    func testDeniedPermissionNeverWritesButReadOnlySnapshotRemainsHonest() {
        check { h in
            h.allowed = false
            h.controller.perform(level: 60)
            XCTAssertNotNil(h.controller.error)
            XCTAssertEqual(h.defaultReads, 0, "Denied ownership/call/guard permission stops before HAL")
            let state = h.controller.snapshot
            XCTAssertEqual(state["available"] as? Bool, true)
            XCTAssertEqual(state["can_set"] as? Bool, false)
            XCTAssertEqual(state["level"] as? Double, 25)
            XCTAssertEqual(state["status"] as? String, h.controller.error)
            XCTAssertEqual(state["error"] as? String, h.controller.error)
            XCTAssertTrue(h.writes.isEmpty)
        }
    }

    func testRouteChangeAfterSnapshotCannotAuthorizeAStaleWrite() {
        check { h in
            XCTAssertEqual(h.controller.snapshot["can_set"] as? Bool, true)
            h.output = 43
            h.controller.perform(level: 60)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
        }
    }

    func testRouteChangeBetweenReadAndWriteIsRejected() {
        check { h in
            h.onRead = { h.output = 42 }
            h.controller.perform(level: 60)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
            XCTAssertTrue(h.controller.snapshot["level"] is NSNull)
        }
    }

    func testFinalPropertyProbeCannotChangeRouteOrPermissionUnnoticed() {
        check { h in
            h.onWritable = { if h.queried.count == 2 { h.output = 42 } }
            h.controller.perform(level: 60)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
        }
        check { h in
            h.onWritable = { if h.queried.count == 2 { h.allowed = false } }
            h.controller.perform(level: 60)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
        }
    }

    func testOwnershipOrSelectedBudsChangedDuringReadRejectsWrite() {
        check { h in
            h.onRead = { h.allowed = false }
            h.controller.perform(level: 60)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
        }
        check { h in
            h.onRead = { h.selected = "11:22:33:44:55:66" }
            h.controller.perform(level: 60)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
        }
    }

    func testIdentityAndLivenessRecheckedImmediatelyBeforeWrite() {
        check { h in
            h.onEndpoint = { if h.endpointReads == 3 { h.endpoints[41]?.uid = "11-22-33-44-55-66:output" } }
            h.controller.perform(level: 60)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
        }
        check { h in
            h.onEndpoint = { if h.endpointReads == 3 { h.endpoints[41]?.alive = false } }
            h.controller.perform(level: 60)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
        }
    }

    func testPropertyWritabilityRecheckedAfterRead() {
        check { h in
            h.onRead = { h.properties[.virtualMain] = false }
            h.controller.perform(level: 60)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
        }
        check { h in
            h.onRead = { h.properties[.virtualMain] = nil }
            h.controller.perform(level: 60)
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertNotNil(h.controller.error)
        }
    }

    func testWriteFailurePersistsInSnapshotsWithoutFallbackOrRetry() {
        check { h in
            h.properties = [.virtualMain: true, .mainScalar: true]
            h.writeFails = true
            h.controller.perform(level: 60)
            for _ in 0..<3 {
                let state = h.controller.snapshot
                XCTAssertEqual(state["status"] as? String, "Falha de escrita simulada.")
                XCTAssertEqual(state["error"] as? String, "Falha de escrita simulada.")
                XCTAssertEqual(state["level"] as? Double, 25)
            }
            XCTAssertEqual(h.writes.count, 1)
            XCTAssertFalse(h.queried.contains(.mainScalar))
            h.writeFails = false
            h.controller.perform(level: 50)
            XCTAssertNil(h.controller.error)
            XCTAssertTrue(h.controller.snapshot["error"] is NSNull)
        }
    }

    func testInvalidHALReadingsNeverFabricateLevelOrAuthorizeWrite() {
        check { h in
            for scalar: Float32 in [.nan, .infinity, -.infinity, -0.1, 1.1] {
                h.scalar = scalar
                h.controller.perform(level: 40)
                XCTAssertNotNil(h.controller.error)
                XCTAssertTrue(h.controller.snapshot["level"] is NSNull)
            }
            XCTAssertTrue(h.writes.isEmpty)
        }
    }

    func testFailedOrUnconfirmedReadbackNeverPublishesRequestedLevel() {
        check { h in
            h.applyWrite = false
            h.controller.perform(level: 80)
            XCTAssertEqual(h.writes.count, 1)
            XCTAssertNotNil(h.controller.error)
            XCTAssertEqual(h.controller.snapshot["level"] as? Double, 25)
        }
        check { h in
            h.afterWrite = { h.readFails = true }
            h.controller.perform(level: 80)
            XCTAssertEqual(h.writes.count, 1)
            XCTAssertEqual(h.controller.error, "Falha de leitura simulada.")
            XCTAssertTrue(h.controller.snapshot["level"] is NSNull)
        }
    }

    func testRouteLossDuringReadbackDoesNotWriteOrAdjustNewOutput() {
        check { h in
            h.afterWrite = { h.output = 42 }
            h.controller.perform(level: 80)
            XCTAssertEqual(h.writes.count, 1)
            XCTAssertEqual(h.writes.first?.0, 41)
            XCTAssertNotNil(h.controller.error)
            XCTAssertTrue(h.controller.snapshot["level"] is NSNull)
        }
    }

    func testExternalVolumeChangesAppearInFreshSerializableSnapshots() throws {
        try check { h in
            let first = h.controller.snapshot
            h.scalar = 0.75
            let second = h.controller.snapshot
            XCTAssertEqual(first["level"] as? Double, 25)
            XCTAssertEqual(second["level"] as? Double, 75)
            XCTAssertEqual(Set(second.keys), ["available", "can_set", "level", "status", "error"])
            XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: second))
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertEqual(h.reads, 2)
        }
    }

    func testMalformedOrMissingSelectionNeverMatchesAnAudioUID() {
        check { h in
            for selection in ["", "Galaxy Buds", "AA:BB:CC:DD:EE", "xxAABBCCDDEEFF", "AA:BB:CC:DD:EE:FF:output"] {
                h.selected = selection
                h.controller.perform(level: 40)
                XCTAssertNotNil(h.controller.error)
                XCTAssertTrue(h.controller.snapshot["level"] is NSNull)
            }
            XCTAssertTrue(h.writes.isEmpty)
            XCTAssertEqual(h.defaultReads, 0)
        }
    }
}
