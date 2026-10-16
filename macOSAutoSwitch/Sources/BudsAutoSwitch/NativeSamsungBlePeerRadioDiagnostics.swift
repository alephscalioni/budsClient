import Foundation

enum NativeSamsungPeerRadioStrategy: String, Codable { case classicFirst, advertisedLEFirst }
/// Typed closed vocabulary only. Optional fields mean that carrier was not
/// attempted/observed; never fill it from OS errors or arbitrary dictionaries.
struct NativeSamsungPeerRadioSummary: Codable, Equatable {
    struct Classic: Codable, Equatable {
        let phase: NativeSamsungPeerDiagnostics.Phase
        let failure: NativeSamsungPeerFailure?
        let pendingOperations: Int
    }
    struct BLE: Codable, Equatable {
        let phase: NativeSamsungBlePeerDiagnostics.Phase
        let reason: NativeSamsungBlePeerDiagnostics.Reason?
        let candidates: Int
        let channelsOpened: Int
    }
    var strategy: NativeSamsungPeerRadioStrategy?
    var termination: NativeSamsungPeerFailure?
    var classic: Classic?
    var ble: BLE?
    var safeValues: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return values
    }
}
@MainActor protocol NativeSamsungPeerRadioDiagnosticSource: AnyObject {
    var radioSummary: NativeSamsungPeerRadioSummary { get }
}
extension NativeSamsungPeerRadioDiagnosticSource {
    var radioSummary: NativeSamsungPeerRadioSummary { .init() }
}
extension NativeSamsungPeerTransport: NativeSamsungPeerRadioDiagnosticSource {
    var radioSummary: NativeSamsungPeerRadioSummary {
        let d = diagnostics
        return .init(classic: .init(phase: d.phase, failure: d.failure, pendingOperations: d.pendingOperations))
    }
}
extension NativeSamsungBlePeerCentral: NativeSamsungPeerRadioDiagnosticSource {
    var radioSummary: NativeSamsungPeerRadioSummary {
        let d = diagnostics
        return .init(ble: .init(phase: d.phase, reason: d.reason, candidates: d.candidates, channelsOpened: d.channelsOpened))
    }
}
