import Foundation

// Legacy bridge data types, also used by the native UI empty phone-choice contract.
struct PhoneDevice: Identifiable, Hashable {
    let id: String
    let name: String
}
struct PhoneState: Decodable {
    let ok: Bool
    let error: String?
    let bluetoothOn: Bool?
    let mediaActive: Bool?
    let callActive: Bool?
    let stateKnown: Bool?
    let a2dpConnected: Bool?
    let headsetConnected: Bool?
    let mediaSessionKnown: Bool?
    let mediaPauseConfirmed: Bool?
}

