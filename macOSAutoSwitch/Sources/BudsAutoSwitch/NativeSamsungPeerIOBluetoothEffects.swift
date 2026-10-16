import Foundation
@preconcurrency import IOBluetooth

/// Explicitly instantiate/use only after the host authorizes concrete peer I/O.
/// Initialization performs no IOBluetooth/device calls. Tests inject fake effects.
@MainActor final class NativeSamsungPeerIOBluetoothEffects: NativeSamsungPeerEffects {
    private let executor = NativeSDKSerialExecutor(name: "NativeSamsungPeer.SDK")
    func start(_ request: NativeSamsungPeerRequest, operation: NativeSamsungPeerOperation) {
        // Extract actor-owned immutable input before crossing to the SDK thread.
        let id = operation.id
        let sdkExecutor = executor
        switch request {
        case .connect(let peer):
            let address = Self.classicString(peer)
            executor.submit {
                guard operation.invocation.claim(at: ProcessInfo.processInfo.systemUptime) else {
                    DispatchQueue.main.async { operation.onReturn(false, nil, nil) }; return
                }
                let target = NativeSamsungPeerSDKReceiver(operation: operation, executor: sdkExecutor)
                guard let device = IOBluetoothDevice(addressString: address) else { target.returned(false); return }
                target.device = device
                if device.isConnected() {
                    target.result(.connected(true)); target.returned(true); return
                }
                let status = device.openConnection(target, withPageTimeout: 12800, authenticationRequired: false)
                // "Connection Exists" can be a non-success return on modern macOS.
                if status != kIOReturnSuccess, device.isConnected() {
                    target.result(.connected(true)); target.returned(true)
                } else { target.returned(status == kIOReturnSuccess) }
            }
        case .discover(let peer):
            let address = Self.classicString(peer)
            executor.submit {
                guard operation.invocation.claim(at: ProcessInfo.processInfo.systemUptime) else {
                    DispatchQueue.main.async { operation.onReturn(false, nil, nil) }; return
                }
                let target = NativeSamsungPeerSDKReceiver(operation: operation, executor: sdkExecutor)
                guard let device = IOBluetoothDevice(addressString: address) else { target.returned(false); return }
                target.device = device
                target.returned(device.performSDPQuery(target, uuids: [NativeSamsungPeerSDKReceiver.uuid()]) == kIOReturnSuccess)
            }
        case .open(let peer, let channelID):
            let address = Self.classicString(peer)
            executor.submit {
                guard operation.invocation.claim(at: ProcessInfo.processInfo.systemUptime) else {
                    DispatchQueue.main.async { operation.onReturn(false, nil, nil) }; return
                }
                let target = NativeSamsungPeerSDKReceiver(operation: operation, executor: sdkExecutor)
                guard let device = IOBluetoothDevice(addressString: address) else { target.returned(false); return }
                target.device = device
                let wrapper = NativeSamsungPeerSDKChannel(receiver: target)
                target.wrapper = wrapper // weak: operation return/result and lease own the wrapper
                var channel: IOBluetoothRFCOMMChannel?
                let status = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: target)
                wrapper.channel = channel
                target.returned(status == kIOReturnSuccess, channel: channel == nil ? nil : wrapper)
                // A synchronous open callback is held until out-parameter assignment.
                target.flushOpen()
            }
        case .write(let channel, let buffer):
            executor.submit {
                guard operation.invocation.claim(at: ProcessInfo.processInfo.systemUptime) else {
                    DispatchQueue.main.async { operation.onReturn(false, nil, nil) }; return
                }
                guard let wrapper = channel as? NativeSamsungPeerSDKChannel, let io = wrapper.channel else {
                    DispatchQueue.main.async { operation.onReturn(false, nil, nil) }; return
                }
                guard buffer.bytes.length > 0, buffer.bytes.length <= Int(UInt16.max),
                      buffer.bytes.length <= Int(io.getMTU()) else {
                    DispatchQueue.main.async { operation.onReturn(false, nil, nil) }; return
                }
                let status = io.writeSync(buffer.bytes.mutableBytes, length: UInt16(buffer.bytes.length))
                DispatchQueue.main.async {
                    operation.onReturn(status == kIOReturnSuccess, nil, nil)
                    if status == kIOReturnSuccess {
                        operation.onResult(.written(channel: wrapper, id: id, success: true, bytesWritten: buffer.bytes.length))
                    }
                }
            }
        }
    }
    func close(_ channel: any NativeSamsungPeerChannel, completion: @escaping @MainActor (Bool) -> Void) {
        executor.submit {
            guard let wrapper = channel as? NativeSamsungPeerSDKChannel, let io = wrapper.channel else {
                DispatchQueue.main.async { completion(false) }; return
            }
            // The serial worker reaches this only after a running write returns.
            // No baseband close and no synthetic remote-delivery acknowledgment.
            let success = io.close() == kIOReturnSuccess
            if success { io.setDelegate(nil) }
            DispatchQueue.main.async { completion(success) }
        }
    }
    private static func classicString(_ peer: NativeSamsungPeerVerifiedAddress) -> String {
        peer.address.bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}

private final class NativeSamsungPeerSDKChannel: NativeSamsungPeerChannel, @unchecked Sendable {
    var channel: IOBluetoothRFCOMMChannel?
    let receiver: NativeSamsungPeerSDKReceiver
    init(receiver: NativeSamsungPeerSDKReceiver) { self.receiver = receiver }
}

/// Retained by operation/drain during initiation and channel during its lifetime.
/// Apple does not retain the RFCOMM delegate on macOS 10.6+.
private final class NativeSamsungPeerSDKReceiver: NSObject, IOBluetoothRFCOMMChannelDelegate, @unchecked Sendable {
    let operation: NativeSamsungPeerOperation
    let executor: NativeSDKSerialExecutor
    var device: IOBluetoothDevice?
    weak var wrapper: NativeSamsungPeerSDKChannel?
    private var openResult: (IOBluetoothRFCOMMChannel, IOReturn)?
    private var didReturnOpen = false
    private let lock = NSLock()
    private var queuedBytes = 0
    private var overrun = false
    init(operation: NativeSamsungPeerOperation, executor: NativeSDKSerialExecutor) {
        self.operation = operation; self.executor = executor
    }
    static func uuid() -> IOBluetoothSDPUUID {
        IOBluetoothSDPUUID(data: Data([0x3a, 0x62, 0x2e, 0x58, 0xc0, 0x35, 0x4a, 0x26,
                                      0x92, 0x8c, 0x56, 0x01, 0xdd, 0xe7, 0xc6, 0x57]))
    }
    func returned(_ success: Bool, channel: NativeSamsungPeerSDKChannel? = nil) {
        let op = operation
        DispatchQueue.main.async { [self] in op.onReturn(success, channel, self) }
    }
    func result(_ value: NativeSamsungPeerResult) {
        let op = operation
        DispatchQueue.main.async { op.onResult(value) }
    }
    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        executor.submit { [self] in
            guard device === self.device else { return }
            result(.connected(status == kIOReturnSuccess))
        }
    }
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        executor.submit { [self] in
            guard device === self.device else { return }
            var id: BluetoothRFCOMMChannelID = 0
            // No cached/guessed ID unless the requested UUID has an actual record.
            let found = status == kIOReturnSuccess && device.getServiceRecord(for: Self.uuid())?.getRFCOMMChannelID(&id) == kIOReturnSuccess
            result(.discovered(success: status == kIOReturnSuccess, recordChannel: found && (1...30).contains(id) ? id : nil))
        }
    }
    func rfcommChannelOpenComplete(_ channel: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        guard let channel else { result(.opened(nil, success: false, mtu: 0)); return }
        executor.submit { [self] in
            openResult = (channel, status)
            if didReturnOpen { publishOpen() }
        }
    }
    func flushOpen() { didReturnOpen = true; publishOpen() }
    private func publishOpen() {
        guard let (io, status) = openResult else { return }; openResult = nil
        guard let wrapper, io === wrapper.channel else {
            // This target is registered only for this outgoing open, never globally.
            io.setDelegate(nil); _ = io.close(); result(.opened(nil, success: false, mtu: 0)); return
        }
        result(.opened(wrapper, success: status == kIOReturnSuccess && io.isOpen(), mtu: Int(io.getMTU())))
    }
    func rfcommChannelData(_ channel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length count: Int) {
        guard count > 0 else { return }
        lock.lock()
        guard let pointer, count <= 65536, queuedBytes <= 262144 - count else {
            if !overrun {
                overrun = true
                executor.submit { [self] in
                    guard let wrapper, channel === wrapper.channel else { return }
                    DispatchQueue.main.async { [operation] in operation.onBytes(wrapper, nil) }
                }
            }
            lock.unlock(); return
        }
        let bytes = Data(bytes: pointer, count: count); queuedBytes += count
        executor.submit { [self] in
            guard let wrapper, channel === wrapper.channel else {
                lock.lock(); queuedBytes -= count; lock.unlock(); return
            }
            DispatchQueue.main.async { [self] in
                defer { lock.lock(); queuedBytes -= count; lock.unlock() }
                operation.onBytes(wrapper, bytes)
            }
        }
        lock.unlock()
    }
    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        executor.submit { [self] in
            guard let wrapper, channel === wrapper.channel else { return }
            DispatchQueue.main.async { [operation] in operation.onClosed(wrapper) }
        }
    }
}
