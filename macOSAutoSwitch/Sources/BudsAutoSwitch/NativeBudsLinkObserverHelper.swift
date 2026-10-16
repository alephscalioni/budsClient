import Foundation
import IOBluetooth
import Darwin

/// A retired notification handle cannot enqueue a link fact after replacement.
/// Capture identity is checked under a lock at ingress, not after an actor hop.
private final class NativeIOBluetoothLinkNotificationIdentity: @unchecked Sendable {
    private let lock = NSLock()
    private var connect: IOBluetoothUserNotification?
    private var disconnect: IOBluetoothUserNotification?

    func set(_ notification: IOBluetoothUserNotification?, forConnect: Bool) {
        lock.lock(); defer { lock.unlock() }
        if forConnect { connect = notification } else { disconnect = notification }
    }

    func matches(_ notification: IOBluetoothUserNotification, forConnect: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (forConnect ? connect : disconnect) === notification
    }
}

/// Only passive SDK notification registration/unregistration. In particular,
/// IOBluetoothDevice.isConnected() is stale on macOS 27 and is never consulted.
@MainActor private final class NativeIOBluetoothLinkSubscription: NSObject {
    private nonisolated let address: String
    private nonisolated let receive: (@Sendable (Bool, TimeInterval) -> UInt64?)
    private nonisolated let identity = NativeIOBluetoothLinkNotificationIdentity()
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotification: IOBluetoothUserNotification?
    private var lastRegistrationSequence: UInt64 = 0
    private var active = false

    init(address: String, receive: @escaping (@Sendable (Bool, TimeInterval) -> UInt64?)) {
        self.address = address; self.receive = receive
    }

    func start() -> Bool {
        guard let device = IOBluetoothDevice(addressString: address) else { return false }
        active = true
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self,
            selector: #selector(didConnect(_:device:)))
        identity.set(connectNotification, forConnect: true)
        guard connectNotification != nil else { return false }
        // Register before the async baseline so its entire observation window
        // is covered, regardless of stale device properties.
        return observeDisconnect(device)
    }

    func stop() {
        active = false
        identity.set(nil, forConnect: true); identity.set(nil, forConnect: false)
        connectNotification?.unregister(); connectNotification = nil
        disconnectNotification?.unregister(); disconnectNotification = nil
    }

    private func observeDisconnect(_ device: IOBluetoothDevice) -> Bool {
        if disconnectNotification != nil { return true }
        disconnectNotification = device.register(forDisconnectNotification: self,
            selector: #selector(didDisconnect(_:device:)))
        identity.set(disconnectNotification, forConnect: false)
        return disconnectNotification != nil
    }

    // Capture at notification ingress. Delivery onto MainActor may race selection
    // or another callback; subscription identity, timestamp and monitor generation fence it.
    @objc nonisolated private func didConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? ""
        let capturedAt = ProcessInfo.processInfo.systemUptime
        guard identity.matches(notification, forConnect: true),
              MacAudio.normalize(address) == MacAudio.normalize(self.address),
              let sequence = receive(true, capturedAt) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.active, self.connectNotification === notification,
                  sequence > self.lastRegistrationSequence else { return }
            self.lastRegistrationSequence = sequence
            // Rearm for this link. Previously captured receipts remain facts
            // even if their registration has since been replaced.
            self.identity.set(nil, forConnect: false)
            self.disconnectNotification?.unregister(); self.disconnectNotification = nil
            _ = self.observeDisconnect(device)
        }
    }

    @objc nonisolated private func didDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? ""
        let capturedAt = ProcessInfo.processInfo.systemUptime
        guard identity.matches(notification, forConnect: false),
              MacAudio.normalize(address) == MacAudio.normalize(self.address),
              let sequence = receive(false, capturedAt) else { return }
        Task { @MainActor [weak self] in
            guard let self, self.active, sequence > self.lastRegistrationSequence else { return }
            self.lastRegistrationSequence = sequence
            self.identity.set(nil, forConnect: false)
            self.disconnectNotification?.unregister(); self.disconnectNotification = nil
        }
    }
}

/// Separate process: notification registration on macOS 27 can overwrite the
/// live state cached by IOBluetooth device objects used by RFCOMM in that process.
/// This mode has only passive registrations and stdout; no audio/channel effects.
enum NativeBudsLinkObserverHelper {
    static let flag = "--buds-passive-link-observer"
    @MainActor static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.contains(flag) else { return false }
        guard args.count == 6, args[1] == flag, args[2] == "--address", args[4] == "--owner-pid",
              let owner = Int32(args[5]), owner > 1, owner == getppid(),
              MacAudio.normalize(args[3]).count == 12 else { exit(64) }
        let sink = NativeBudsLinkEventSink()
        let subscription = NativeIOBluetoothLinkSubscription(address: args[3], receive: { sink.send($0, at: $1) })
        guard subscription.start() else { subscription.stop(); exit(1) }
        sink.ready()
        while getppid() == owner && kill(owner, 0) == 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        subscription.stop()
        return true
    }
}

private final class NativeBudsLinkEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var started = false
    private var pending: [Data] = []
    func ready() {
        lock.lock(); defer { lock.unlock() }
        let event: [String: Any] = ["event": "ready", "uptime": ProcessInfo.processInfo.systemUptime]
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { exit(1) }
        do {
            try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
            for event in pending { try FileHandle.standardOutput.write(contentsOf: event) }
            pending.removeAll(); started = true
        }
        catch { exit(1) }
    }
    func send(_ connected: Bool, at time: TimeInterval) -> UInt64? {
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        let event: [String: Any] = ["event": "link", "sequence": sequence, "connected": connected, "uptime": time]
        guard let data = try? JSONSerialization.data(withJSONObject: event) else { return nil }
        if !started {
            guard pending.count < 64 else { exit(1) }
            pending.append(data + Data([10])); return sequence
        }
        do { try FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
        catch { return nil }
        return sequence
    }
}
