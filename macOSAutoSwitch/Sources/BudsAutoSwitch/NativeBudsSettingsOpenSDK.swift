import Foundation
@preconcurrency import IOBluetooth

/// The caller checks a fresh OS Bluetooth observation before each operation.
/// IOBluetoothDevice.isConnected() is empirically stale on macOS 27 and must not
/// veto that observation. Neither operation explicitly opens a baseband link.
enum NativeBudsSettingsOpenSDK {
    @MainActor static func effects(device: IOBluetoothDevice, address: String,
                                   uuid: IOBluetoothSDPUUID) -> NativeBudsSettingsOpenEffects<IOBluetoothRFCOMMChannel> {
        var currentReceiver: ChannelReceiver?
        return .init(connected: { try await MacAudio.isBluetoothConnected(address) },
              serviceChannel: { serviceChannel(device, uuid: uuid) },
              discover: { completion in
                  let receiver = DiscoveryReceiver(device: device, completion)
                  // Upstream Bluetooth.mm: the UUID-filtered query silently fails
                  // since Ventura. Selection still uses ONLY the requested UUID.
                  let status = device.performSDPQuery(receiver)
                  if status != kIOReturnSuccess { completion(status) }
                  return receiver
              }, open: { id, callbacks, completion in
                  let receiver = ChannelReceiver(callbacks)
                  currentReceiver = receiver
                  NativeBudsSettingsOpenWorker.run(open: {
                      guard !callbacks.isCancelled,
                            serviceChannel(device, uuid: uuid) == id else { return (kIOReturnNotOpen, nil) }
                      var channel: IOBluetoothRFCOMMChannel?
                      let status = device.openRFCOMMChannelSync(&channel, withChannelID: id, delegate: receiver)
                      // The SDK can return an existing channel. Register the owned,
                      // retained receiver explicitly rather than trusting isOpen.
                      if let channel {
                          let registration = channel.setDelegate(receiver)
                          receiver.delegateRegistered = registration == kIOReturnSuccess
                          if registration != kIOReturnSuccess { return (registration, channel) }
                      }
                      return (status, channel)
                  }, isOpen: { receiver.ownsOpenChannel($0) }, completion: completion)
                  return receiver
              }, isOpen: { currentReceiver?.ownsOpenChannel($0) == true }, close: { channel in
                  NativeBudsSDKWriter.close(channel)
              }, refreshServiceBeforeOpen: true)
    }
    private static func serviceChannel(_ device: IOBluetoothDevice, uuid: IOBluetoothSDPUUID) -> UInt8? {
        var id: BluetoothRFCOMMChannelID = 0
        guard let record = device.getServiceRecord(for: uuid),
              record.getRFCOMMChannelID(&id) == kIOReturnSuccess, (1...30).contains(id) else { return nil }
        return id
    }
    private final class DiscoveryReceiver: NSObject {
        private let device: IOBluetoothDevice
        private let completion: @MainActor (Int32) -> Void
        init(device: IOBluetoothDevice, _ completion: @escaping @MainActor (Int32) -> Void) {
            self.device = device; self.completion = completion
        }
        @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
            DispatchQueue.main.async { self.completion(status) }
        }
    }
    private final class ChannelReceiver: NSObject, IOBluetoothRFCOMMChannelDelegate, NativeBudsSDKCloseObserving {
        let callbacks: NativeBudsSettingsOpenCallbacks<IOBluetoothRFCOMMChannel>
        // Set by the serial open worker; consumed there and after its main-queue
        // completion. No later mutation or optimistic permission from isOpen alone.
        var delegateRegistered = false
        init(_ callbacks: NativeBudsSettingsOpenCallbacks<IOBluetoothRFCOMMChannel>) { self.callbacks = callbacks }
        func ownsOpenChannel(_ channel: IOBluetoothRFCOMMChannel) -> Bool {
            delegateRegistered && channel.isOpen() && (channel.delegate() as? ChannelReceiver) === self
        }
        func observedClose(of channel: AnyObject) -> Bool {
            guard let channel = channel as? IOBluetoothRFCOMMChannel else { return false }
            return callbacks.observedClose(of: channel)
        }
        func whenClosed(_ channel: AnyObject, completion: @escaping @Sendable () -> Void) {
            guard let channel = channel as? IOBluetoothRFCOMMChannel else { return }
            callbacks.whenClosed(channel, completion: completion)
        }
        func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
            callbacks.receive(.opened(channel, status))
        }
        func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data: UnsafeMutableRawPointer!, length: Int) {
            callbacks.receive(channel, pointer: data, count: length)
        }
        func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) { callbacks.receive(.closed(channel)) }
        func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status: IOReturn) {
            callbacks.receive(.written(channel, UInt(bitPattern: refcon), status, nil))
        }
        func rfcommChannelWriteComplete(_ channel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status: IOReturn, bytesWritten: Int) {
            callbacks.receive(.written(channel, UInt(bitPattern: refcon), status, bytesWritten))
        }
    }
}
