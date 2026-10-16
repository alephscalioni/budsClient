import Foundation

/// GET-first lifecycle. Call only from an explicit native action. No startup
/// hook, identity registration, token renewal, automatic PATCH or silent reset.
@MainActor
final class SamsungCloudCertificateEnrollment {
    typealias C = SamsungCloudCertificate
    typealias Transport = (URLRequest) async throws -> (Data, Int)
    enum Action {
        case retrieve
        /// Explicit consent to a new enrollment, with an explicitly typed own local identity.
        /// Even this action cannot POST unless the preceding GET returned 204.
        case enroll(C.Device)
    }
    enum Stage: String { case getKC01 = "GET_KC01", postKC01 = "POST_KC01", patchDevice = "PATCH_DEVICE", ers = "ERS" }
    struct Result {
        let diagnostics: C.Diagnostics
        let blocker: C.Failure?
        var httpStatus: Int? = nil
        var stage: Stage? = nil
        var serviceCode: String? = nil
        var identityMode: C.IdentityMode? = nil
        var publicValues: [String: Any] {
            var values = diagnostics.publicValues.mapValues { $0 as Any }
            values["certificate_blocker"] = blocker?.rawValue ?? ""
            values["certificate_http_status"] = httpStatus.map { $0 as Any } ?? NSNull()
            values["certificate_stage"] = stage?.rawValue ?? ""
            values["certificate_service_code"] = serviceCode ?? ""
            values["continuity_identity_mode"] = identityMode?.rawValue ?? ""
            values["continuity_outgoing_only"] = identityMode == .outgoingClassicApplication
            values["continuity_incoming_ble_discovery_available"] = false
            values["native_switch_validated"] = false
            return values
        }
        var humanStatus: String {
            if blocker == nil && diagnostics.certificateKeychainReady && diagnostics.peerRosterContainsThisDevice {
                return identityMode == .outgoingClassicApplication
                    ? "Continuidade preparada para conexões de saída por Bluetooth Classic. Descoberta BLE de entrada indisponível. A conexão com o telefone ainda precisa ser validada."
                    : "Certificados preparados. A autenticação com o outro dispositivo ainda precisa ser validada."
            }
            switch blocker {
            case .existingCertificateWithoutOwnedKey:
                return "O Cloud já tem um certificado, mas a chave privada própria não está nas Chaves deste Mac. O certificado não foi substituído."
            case .authRejected: return "O serviço recusou a autorização para o certificado. A sessão salva foi preservada."
            case .peerRosterMismatch: return "O cadastro do Cloud ainda não confirma o endereço e a identidade deste Mac."
            case .continuityIdentityMismatch: return "A identidade de continuidade salva não corresponde a este Mac. Ela foi preservada."
            case .continuityIdentityUnavailable, .keychainUnavailable: return "A identidade protegida nas Chaves está indisponível."
            case .missingBluetoothIdentity: return "Não foi possível confirmar o endereço Bluetooth Classic deste Mac."
            default: return "A preparação da continuidade está pendente. A sessão salva foi preservada."
            }
        }
    }
    /// Only a closed-looking service code, never a message or arbitrary body.
    static func serviceCode(_ data: Data) -> String? {
        guard data.count <= 65_536, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for field in ["errorCode", "code", "error_code"] {
            if let code = object[field] as? String,
               code.range(of: "^[A-Z][A-Z0-9_]{1,63}\\z", options: .regularExpression) != nil { return code }
        }
        return nil
    }
    private let session: C.Session
    private let context: C.Context
    private let vault: SamsungCloudCertificateVault
    private let transport: Transport
    private var running = false

    init(session: C.Session, context: C.Context, vault: SamsungCloudCertificateVault, transport: @escaping Transport) {
        self.session = session; self.context = context; self.vault = vault; self.transport = transport
    }

    func prepare(_ action: Action = .retrieve, identity: C.LocalIdentity? = nil, now: Date? = nil) async -> Result {
        guard !running else { return Result(diagnostics: C.Diagnostics(), blocker: .explicitConsentRequired) }
        running = true; defer { running = false }
        let currentTime = { now ?? Date() }
        var state = C.Diagnostics(accountAuthenticated: true, cloudIdentityRegistered: true)
        let local: C.LocalIdentity?
        if case .enroll(let device) = action { local = device.identity } else { local = identity }
        var httpStatus: Int?
        var stage: Stage? = .getKC01
        var serviceCode: String?
        func result(_ blocker: C.Failure?) -> Result {
            Result(diagnostics: state, blocker: blocker, httpStatus: httpStatus, stage: stage,
                   serviceCode: serviceCode, identityMode: local?.mode)
        }
        do {
            let stored = try vault.readMaterial()
            // Old expiry must not erase the revision floor or trigger new keys.
            let previousRevision = stored.flatMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["revision"] as? Int }
            if let stored, let cached = try? C.Material.decode(stored, now: currentTime()) {
                state.peerRosterContainsThisDevice = cached.containsThisDevice(session.deviceID, identity: local)
                state.certificateKeychainReady = (try? cached.validateOwnedKey(vault.publicKey(), deviceID: session.deviceID, now: currentTime())) != nil
            }
            try Task.checkCancellation()
            // Unconditional full GET avoids interpreting 304 without a usable cache.
            let (data, status) = try await transport(context.request(session: session, method: "GET"))
            httpStatus = status
            if status != 200 && status != 204 { serviceCode = Self.serviceCode(data) }
            try Task.checkCancellation()
            let response: Data
            switch status {
            case 200: response = data
            case 204:
                // A missing remote certificate must never silently replace an
                // existing local identity/material, even after expiry.
                guard stored == nil else { throw C.Failure.invalidCertificate }
                guard case .enroll(let device) = action else {
                    throw local == nil ? C.Failure.missingBluetoothIdentity : C.Failure.explicitConsentRequired
                }
                try device.validate()
                // Staged permanent key survives network failures and retries.
                let csr = try vault.createCSR(deviceID: session.deviceID)
                try Task.checkCancellation()
                guard let ownedKey = try vault.publicKey() else { throw C.Failure.privateKeyUnavailable }
                guard try SamsungCloudCertificateDER.validateCSR(csr, deviceID: session.deviceID) == ownedKey else { throw C.Failure.invalidCSR }
                let request = try context.request(session: session, method: "POST", device: device, csr: csr)
                stage = .postKC01; httpStatus = nil
                let (generated, generatedStatus) = try await transport(request)
                httpStatus = generatedStatus
                try Task.checkCancellation()
                guard generatedStatus == 200 || generatedStatus == 201 else {
                    serviceCode = Self.serviceCode(generated); throw Self.failure(generatedStatus)
                }
                response = generated
            default: throw Self.failure(status)
            }
            let material = try C.Material.decode(response, now: currentTime(), minimumRevision: previousRevision)
            state.peerRosterContainsThisDevice = material.containsThisDevice(session.deviceID, identity: local)
            try material.validateOwnedKey(vault.publicKey(), deviceID: session.deviceID, now: currentTime())
            // Reject a changed identity before overwriting previously valid material.
            if local != nil && !state.peerRosterContainsThisDevice { throw C.Failure.peerRosterMismatch }
            let encoded = try material.encodedForKeychain()
            state.certificateKeychainReady = false
            try vault.saveMaterial(encoded)
            // Verify actual persisted bytes and key, rather than just HTTP success.
            guard let saved = try vault.readMaterial(), saved == encoded else { throw C.Failure.keychainUnavailable }
            let readback = try C.Material.decode(saved, now: currentTime(), minimumRevision: material.revision)
            try readback.validateOwnedKey(vault.publicKey(), deviceID: session.deviceID, now: currentTime())
            state.certificateKeychainReady = true
            return result(local == nil ? .missingBluetoothIdentity : nil)
        } catch let failure as C.Failure {
            state.certificateKeychainReady = cachedKeychainReady(now: currentTime())
            return result(failure)
        } catch {
            state.certificateKeychainReady = cachedKeychainReady(now: currentTime())
            return result(.transportFailure)
        }
    }

    private func cachedKeychainReady(now: Date) -> Bool {
        guard let bytes = try? vault.readMaterial(), let material = try? C.Material.decode(bytes, now: now) else { return false }
        return (try? material.validateOwnedKey(vault.publicKey(), deviceID: session.deviceID, now: now)) != nil
    }

    /// Separate, explicitly invoked mutation. Never repairs identity on GET/auth failure.
    func patch(_ patch: C.Patch, now: Date? = nil) async -> Result {
        guard !running else { return Result(diagnostics: C.Diagnostics(), blocker: .explicitConsentRequired) }
        let identity: C.LocalIdentity?
        switch patch {
        case .bluetoothAddress(let local), .irk(let local): identity = local
        case .deviceName: identity = nil
        }
        let before = await prepare(.retrieve, identity: identity, now: now)
        guard before.diagnostics.certificateKeychainReady,
              before.blocker == nil || before.blocker == .missingBluetoothIdentity || before.blocker == .peerRosterMismatch else { return before }
        running = true
        var patchStatus: Int?
        var patchCode: String?
        do {
            try Task.checkCancellation()
            let (data, status) = try await transport(context.request(session: session, method: "PATCH", patch: patch))
            patchStatus = status
            if !(200...299).contains(status) { patchCode = Self.serviceCode(data) }
            try Task.checkCancellation()
            guard (200...299).contains(status) else { throw Self.failure(status) }
            running = false
            // PATCH success alone never claims the roster was updated.
            return await prepare(.retrieve, identity: identity, now: now)
        } catch let failure as C.Failure {
            running = false; return Result(diagnostics: before.diagnostics, blocker: failure, httpStatus: patchStatus, stage: .patchDevice, serviceCode: patchCode, identityMode: identity?.mode)
        } catch {
            running = false; return Result(diagnostics: before.diagnostics, blocker: .transportFailure, httpStatus: patchStatus, stage: .patchDevice, serviceCode: patchCode, identityMode: identity?.mode)
        }
    }

    private static func failure(_ status: Int) -> C.Failure {
        if status == 401 || status == 403 { return .authRejected }
        if [404, 405, 410, 501].contains(status) { return .unsupported }
        return .serverRejected
    }
}
