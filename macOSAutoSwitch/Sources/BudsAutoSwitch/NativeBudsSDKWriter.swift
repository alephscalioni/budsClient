import Foundation
@preconcurrency import IOBluetooth

@MainActor enum NativeBudsSDKWriter {
    private static let executor = NativeSDKSerialExecutor(name: "Buds.RFCOMM.write")
    private static let writer = NativeSerialChannelWriter<IOBluetoothRFCOMMChannel>(
        enqueue: { executor.submit($0) }, write: { channel, bytes in
            guard bytes.length <= Int(channel.getMTU()), bytes.length <= Int(UInt16.max) else { return kIOReturnBadArgument }
            return channel.writeSync(bytes.mutableBytes, length: UInt16(bytes.length))
        }, close: { channel in
            let wasOpen = channel.isOpen()
            let observer = channel.delegate() as? NativeBudsSDKCloseObserving
            let result = channel.close()
            return NativeBudsSDKCloseCompletion.finish(status: result, wasOpen: wasOpen,
                observed: observer.map { observer in { observer.observedClose(of: channel) } },
                isOpen: { channel.isOpen() }, clearDelegate: { channel.setDelegate(nil) })
        }, drain: .shared, settleClose: { channel, completion in
            // A receipt arriving after the bounded worker wait still retires
            // the old lease. Do not require app restart for a slow actual close.
            guard let observer = channel.delegate() as? NativeBudsSDKCloseObserving else { return }
            observer.whenClosed(channel) {
                DispatchQueue.main.async {
                    channel.setDelegate(nil)
                    completion()
                }
            }
        })
    static func send(_ data: Data, channel: IOBluetoothRFCOMMChannel, deadline: TimeInterval,
                     completion: @escaping (Int32, Int) -> Void) -> NativeSDKInvocation? {
        writer.send(data, channel: channel, retaining: channel.delegate() as AnyObject?,
                    deadline: deadline, completion: completion)
    }
    static func close(_ channel: IOBluetoothRFCOMMChannel) {
        writer.close(channel, retaining: channel.delegate() as AnyObject?)
    }
}
