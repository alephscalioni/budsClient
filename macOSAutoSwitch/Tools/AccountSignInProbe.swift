import AppKit
import AuthenticationServices
import Foundation
import Security

/// A separate native diagnostic. It never changes Bluetooth or starts switching.
@MainActor
final class AccountSignInController: NSObject, NSApplicationDelegate, ASWebAuthenticationPresentationContextProviding {
    var onContinuityReady: (() -> Void)?
    private let embedded: Bool
    private var avatarBase64: String?
    private var avatarRevision = 0
    private var connected = false
    private var cloudEnrolled = false
    private var certificateDiagnostics = SamsungCloudCertificate.Diagnostics()
    private var certificateBlocker = "NOT_PREPARED"
    private var certificatePublicValues: [String: Any] = [
        "certificate_http_status": NSNull(), "certificate_stage": "",
        "continuity_identity_mode": "", "continuity_outgoing_only": false,
        "continuity_incoming_ble_discovery_available": false]
    private var authenticationWindow: NSWindow?
    init(embedded: Bool = false) { self.embedded = embedded; super.init() }
    private var window: NSWindow!
    private var status: NSTextField!
    private var profileImage: NSImageView!
    private var profileInitials: NSTextField!
    private var profileName: NSTextField!
    private var profileWork: Task<Void, Never>?
    private var button: NSButton!
    private var cancelButton: NSButton!
    private var cloudButton: NSButton!
    private var identityPanel: NSStackView!
    private var identityField: NSTextField!
    private var identityContinueButton: NSButton!
    private var waitingIdentity: SamsungAccountContinuityProtocol.PendingIdentity?
    private var waitingProfile: SamsungAccountWebProtocol.DeviceProfile?
    private var identityExpiry: Task<Void, Never>?
    private var callbackDiagnostics: [String: Bool] = [:]
    private var session: ASWebAuthenticationSession?
    private var work: Task<Void, Never>?
    private var pending: SamsungAccountWebProtocol.PendingWebSignIn?
    private var generation = UUID()
    private let defaults = UserDefaults.standard
    private let keychainService = "io.github.galaxybudsclient.native-account-research"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !embedded {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Buds · Samsung Account"
        window.isReleasedWhenClosed = false
        }
        let title = NSTextField(labelWithString: "Samsung Account")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString:
            "Conecte sua Samsung Account para sincronizar os dispositivos. O login acontece no site oficial da Samsung, e sua sessão fica protegida nas Chaves do macOS.")
        profileImage = NSImageView()
        profileImage.imageScaling = .scaleProportionallyUpOrDown
        profileImage.wantsLayer = true; profileImage.layer?.cornerRadius = 24; profileImage.layer?.masksToBounds = true
        profileInitials = NSTextField(labelWithString: "SA")
        profileInitials.alignment = .center; profileInitials.font = .systemFont(ofSize: 18, weight: .semibold)
        profileInitials.textColor = .secondaryLabelColor
        let avatar = NSView(); avatar.translatesAutoresizingMaskIntoConstraints = false
        avatar.wantsLayer = true; avatar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor; avatar.layer?.cornerRadius = 24
        avatar.addSubview(profileImage); avatar.addSubview(profileInitials)
        profileImage.frame = NSRect(x: 0, y: 0, width: 48, height: 48)
        profileInitials.frame = NSRect(x: 0, y: 12, width: 48, height: 24)
        NSLayoutConstraint.activate([avatar.widthAnchor.constraint(equalToConstant: 48), avatar.heightAnchor.constraint(equalToConstant: 48)])
        profileName = NSTextField(labelWithString: "Sua conta Samsung")
        profileName.font = .systemFont(ofSize: 14, weight: .semibold)
        let profileHeader = NSStackView(views: [avatar, profileName])
        profileHeader.orientation = .horizontal; profileHeader.spacing = 12
        status = NSTextField(wrappingLabelWithString: "Pronto para abrir account.samsung.com.")
        status.textColor = .secondaryLabelColor
        button = NSButton(title: "Entrar na Samsung Account", target: self, action: #selector(startSignIn))
        button.bezelStyle = .rounded; button.keyEquivalent = "\r"
        cancelButton = NSButton(title: "Cancelar", target: self, action: #selector(cancelSignIn))
        cancelButton.bezelStyle = .rounded; cancelButton.isEnabled = false
        cloudButton = NSButton(title: "Sincronizar dispositivos", target: self, action: #selector(connectCloud))
        cloudButton.bezelStyle = .rounded
        identityField = NSTextField(string: "")
        identityField.placeholderString = "E-mail ou telefone da Samsung Account"
        identityField.setAccessibilityLabel("E-mail ou telefone usado no login Samsung")
        identityField.target = self; identityField.action = #selector(continueWithIdentity)
        identityContinueButton = NSButton(title: "Continuar autorização", target: self, action: #selector(continueWithIdentity))
        identityContinueButton.bezelStyle = .rounded
        identityPanel = NSStackView(views: [NSTextField(wrappingLabelWithString:
            "Confirme o mesmo e-mail ou telefone usado no login. Ele será enviado à Samsung para concluir esta autorização."),
            identityField, identityContinueButton])
        identityPanel.orientation = .vertical; identityPanel.alignment = .leading; identityPanel.spacing = 10
        identityPanel.isHidden = true
        let controls = NSStackView(views: [button, cancelButton])
        controls.orientation = .horizontal; controls.spacing = 10
        let stack = NSStackView(views: [title, profileHeader, explanation, status, identityPanel, controls, cloudButton])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 19
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window?.contentView ?? NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 27)])
        identityField.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if !embedded && !CommandLine.arguments.contains("--profile-only") {
            window.center(); window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        if CommandLine.arguments.contains("--connect-cloud") { connectCloud() }
        else if CommandLine.arguments.contains("--read-bluetooth") { readBluetooth() }
        else if CommandLine.arguments.contains("--inspect-bluetooth-schema") { inspectBluetoothSchema() }
        else { refreshProfile() }
    }

    func bringToFront() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func cancelPending() { cancelSignIn() }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { cancelSignIn() }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The official login belongs to the existing Buds window in embedded mode.
        window ?? authenticationWindow ?? NSApp.keyWindow ?? NSApp.mainWindow!
    }

    func embeddedState(knownAvatarRevision: Int) -> [String: Any] {
        var result: [String: Any] = ["name": profileName?.stringValue ?? "Samsung Account",
         "initials": profileInitials?.stringValue ?? "SA", "avatar_revision": avatarRevision,
         "connected": connected, "cloud_enrolled": cloudEnrolled, "status": status?.stringValue ?? "",
         "owns_window": window != nil,
         "can_sign_in": button?.isEnabled ?? false, "can_cancel": cancelButton?.isEnabled ?? false,
         "can_sync": (cloudButton?.isEnabled ?? false) && connected,
         "needs_identity": !(identityPanel?.isHidden ?? true),
         "can_confirm_identity": identityContinueButton?.isEnabled ?? false]
        if knownAvatarRevision != avatarRevision { result["avatar"] = avatarBase64 ?? "" }
        for (key, value) in certificateDiagnostics.publicValues { result[key] = value }
        for (key, value) in certificatePublicValues { result[key] = value }
        if let storage = SamsungContinuityKeychainBackend.diagnosticSnapshot {
            for (key, value) in storage.publicValues { result[key] = value }
        }
        result["certificate_schema"] = SamsungCertificateSchemaDiagnostics.snapshot
        result["account_authenticated"] = connected
        result["cloud_identity_registered"] = cloudEnrolled
        result["certificate_blocker"] = certificateBlocker
        result["can_prepare_certificate"] = connected && (cloudButton?.isEnabled ?? false)
        return result
    }

    func embeddedAction(_ action: String, identity: String = "") {
        switch action {
        case "sign_in":
            guard button.isEnabled, NSApp.keyWindow != nil || NSApp.mainWindow != nil else { return }
            authenticationWindow = NSApp.keyWindow ?? NSApp.mainWindow
            startSignIn()
        case "cancel": cancelSignIn()
        case "sync": if cloudButton.isEnabled && connected { connectCloud() }
        case "prepare_certificate": if connected && cloudButton.isEnabled { prepareCertificate() }
        case "enroll_continuity", "account.enroll_continuity":
            if connected && cloudButton.isEnabled { prepareCertificate(enrollContinuity: true) }
        case "identity":
            guard !identityPanel.isHidden, identityContinueButton.isEnabled else { return }
            identityField.stringValue = identity; continueWithIdentity()
        default: break
        }
    }

    /// Explicit on-demand protected read for the parent's peer transport.
    /// Never invoked by embeddedState or a UI polling loop.
    func preparedOutgoingPeerMaterial() async throws -> SamsungCloudCertificate.PeerMaterial {
        try SamsungCloudProtocol.loadPreparedPeerMaterial(account: try await loadAccount())
    }

    /// Retrieval stays GET-only. Only the explicit enroll_continuity action
    /// selects new own-identity enrollment; neither path renews account tokens.
    private func prepareCertificate(enrollContinuity: Bool = false) {
        cancelSignIn()
        let run = UUID(); generation = run
        setBusy(true); status.stringValue = "Verificando os certificados do Cloud…"
        work = Task { [self] in
            do {
                let account = try await loadAccount()
                let result = enrollContinuity
                    ? await SamsungCloudProtocol.enrollContinuity(account: account)
                    : await SamsungCloudProtocol.prepareCertificates(account: account)
                guard generation == run, !Task.isCancelled else { return }
                certificateDiagnostics = result.diagnostics
                certificateBlocker = result.blocker?.rawValue ?? ""
                certificatePublicValues = result.publicValues
                writeResult(result.publicValues)
                status.stringValue = result.humanStatus
                if result.blocker == nil && result.diagnostics.certificateKeychainReady && result.diagnostics.peerRosterContainsThisDevice {
                    onContinuityReady?()
                }
            } catch {
                guard generation == run else { return }
                certificateBlocker = SamsungCloudCertificate.Failure.missingAccount.rawValue
                certificatePublicValues = SamsungCloudCertificateEnrollment.Result(
                    diagnostics: certificateDiagnostics, blocker: .missingAccount).publicValues
                status.stringValue = "A sessão salva é necessária para preparar os certificados."
            }
            setBusy(false)
        }
    }

    @objc private func cancelSignIn() {
        generation = UUID()
        work?.cancel(); work = nil
        profileWork?.cancel(); profileWork = nil
        session?.cancel(); session = nil
        let old = pending; pending = nil
        let identity = waitingIdentity; waitingIdentity = nil; waitingProfile = nil
        identityExpiry?.cancel(); identityExpiry = nil
        identityPanel?.isHidden = true; identityField?.stringValue = ""
        window?.setContentSize(NSSize(width: 540, height: 500))
        callbackDiagnostics = [:]
        Task { await identity?.cancel() }
        Task { await old?.cancel() }
        if status != nil { status.stringValue = "Tentativa cancelada."; setBusy(false) }
    }

    private func setBusy(_ busy: Bool) { button.isEnabled = !busy; cancelButton.isEnabled = busy; cloudButton.isEnabled = !busy }

    private func installationID() -> String {
        if let existing = defaults.string(forKey: "accountResearchInstallationID"),
           existing.range(of: "^[a-f0-9]{32}\\z", options: .regularExpression) != nil { return existing }
        let created = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(created, forKey: "accountResearchInstallationID")
        return created
    }

    @objc private func startSignIn() {
        cancelSignIn()
        let run = UUID(); generation = run
        setBusy(true); status.stringValue = "Preparando a autorização com a Samsung…"
        work = Task { [self] in
            do {
                let attempt = try SamsungAccountProtocol.Attempt.fresh()
                let profile = SamsungAccountWebProtocol.DeviceProfile(installationID: installationID(),
                    country: "BR", systemVersion: ProcessInfo.processInfo.operatingSystemVersionString)
                let client = SamsungAccountWebProtocol.Client.windowsAccount
                let entry = try await SamsungAccountWebProtocol.discoverEntryPoint(client: client)
                let servers = try await SamsungAccountProtocol.discoverServers()
                status.stringValue = "Verificando se a Samsung aceita o retorno desta autorização…"
                try await SamsungAccountWebProtocol.validateRegisteredCallback(client: client, attempt: attempt)
                try Task.checkCancellation()
                guard generation == run else { return }
                let authorizationURL = try SamsungAccountWebProtocol.authorizationURL(entry: entry, attempt: attempt, profile: profile, client: client)
                let pending = SamsungAccountWebProtocol.PendingWebSignIn(attempt: attempt, client: client, fallbackServers: servers)
                self.pending = pending
                let session = ASWebAuthenticationSession(url: authorizationURL, callbackURLScheme: client.callback.scheme) { [weak self] url, error in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.generation == run else { return }
                        self.session = nil
                        guard let url = url, error == nil else {
                            await pending.cancel(); self.pending = nil
                            self.status.stringValue = "Entrada cancelada ou não concluída no navegador."
                            self.setBusy(false); return
                        }
                        self.complete(callback: url, pending: pending, profile: profile, run: run)
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                status.stringValue = "Entre na janela da Samsung para continuar."
                guard session.start() else { throw SamsungAccountWebProtocol.Failure.invalidResponse }
            } catch SamsungAccountWebProtocol.Failure.rejected(let statusCode, let reason) {
                guard generation == run else { return }
                status.stringValue = "A Samsung recusou preparar a autorização (HTTP \(statusCode)). O navegador não será aberto para repetir o erro."
                writeResult(["account_flow": "windows_sso", "authorization_stage": "application_validation",
                    "authorization_http_status": statusCode, "authorization_error_code": reason, "authorization_completed": false])
                setBusy(false)
            } catch {
                guard generation == run else { return }
                status.stringValue = "Não foi possível iniciar a autorização. Tente novamente."
                setBusy(false)
            }
        }
    }

    private func complete(callback: URL, pending: SamsungAccountWebProtocol.PendingWebSignIn,
                          profile: SamsungAccountWebProtocol.DeviceProfile, run: UUID) {
        work = Task { [self] in
            do {
                status.stringValue = "Validando a autorização…"
                let code = try await pending.consume(callback)
                let username = await pending.username
                callbackDiagnostics = await pending.fieldPresence
                try Task.checkCancellation()
                guard generation == run else { return }
                if let username, !username.isEmpty {
                    await exchangeAuthorization(code: code, username: username, profile: profile, run: run)
                } else {
                    waitingIdentity = SamsungAccountContinuityProtocol.PendingIdentity(code: code)
                    waitingProfile = profile
                    identityPanel.isHidden = false
                    identityContinueButton.isEnabled = true
                    window?.setContentSize(NSSize(width: 540, height: 630))
                    status.stringValue = "Login recebido. Confirme o e-mail ou telefone nesta janela para concluir a autorização."
                    setBusy(true); window?.makeKeyAndOrderFront(nil); window?.makeFirstResponder(identityField)
                    writeResult(["account_flow": "windows_sso", "authorization_stage": "awaiting_identifier",
                        "callback_username_present": false, "authorization_completed": false])
                    identityExpiry = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(120)) } catch { return }
                        guard let self, self.generation == run, self.waitingIdentity != nil else { return }
                        await self.waitingIdentity?.cancel()
                        self.waitingIdentity = nil; self.waitingProfile = nil
                        self.identityPanel.isHidden = true; self.identityField.stringValue = ""
                        self.window?.setContentSize(NSSize(width: 540, height: 500))
                        self.status.stringValue = "A autorização expirou. Entre novamente para continuar."
                        self.setBusy(false)
                    }
                }
            } catch {
                guard generation == run else { return }
                status.stringValue = "O retorno do login não pôde ser validado. A sessão anterior foi preservada."
                writeResult(["account_flow": "windows_sso", "authorization_stage": "callback", "authorization_completed": false])
                setBusy(false)
            }
        }
    }

    @objc private func continueWithIdentity() {
        guard let waitingIdentity, let profile = waitingProfile else { return }
        let identifier: String
        do { identifier = try SamsungAccountContinuityProtocol.loginIdentifier(identityField.stringValue) }
        catch { status.stringValue = "Digite o mesmo e-mail ou telefone usado na página da Samsung."; return }
        let run = generation
        identityContinueButton.isEnabled = false
        work = Task {
            do {
                let (code, username) = try await waitingIdentity.consume(identifier: identifier)
                guard generation == run else { return }
                self.waitingIdentity = nil; waitingProfile = nil; identityExpiry?.cancel(); identityExpiry = nil
                identityPanel.isHidden = true; identityField.stringValue = ""
                window?.setContentSize(NSSize(width: 540, height: 500))
                await exchangeAuthorization(code: code, username: username, profile: profile, run: run)
            } catch {
                guard generation == run else { return }
                self.waitingIdentity = nil; waitingProfile = nil
                identityPanel.isHidden = true; identityField.stringValue = ""
                window?.setContentSize(NSSize(width: 540, height: 500))
                status.stringValue = "A autorização expirou. Entre novamente para continuar."
                setBusy(false)
            }
            identityContinueButton.isEnabled = true
        }
    }

    private func exchangeAuthorization(code: SamsungAccountProtocol.AuthorizedCode, username: String,
                                       profile: SamsungAccountWebProtocol.DeviceProfile, run: UUID) async {
            var stage = "user_auth_token"
            do {
                status.stringValue = "Autorizando a sessão de continuidade Samsung…"
                let root = try await SamsungAccountContinuityProtocol.acquireUserAuth(code: code,
                    physicalAddress: profile.installationID, username: username)
                try Task.checkCancellation()
                guard generation == run else { return }
                let rootSession: [String: Any] = ["root_account_session": root,
                    "auth_host": code.servers.authHost, "api_host": code.servers.apiHost,
                    "installation_id": profile.installationID, "obtained_at": Date().timeIntervalSince1970]
                try await saveToKeychain(JSONSerialization.data(withJSONObject: rootSession), accountName: "samsung-account-root")
                stage = "cloud_account_token"
                status.stringValue = "Obtendo a autorização específica do cliente Cloud…"
                let account = try await SamsungAccountContinuityProtocol.acquireCloudAccount(userAuth: root,
                    servers: code.servers, installationID: profile.installationID)
                try Task.checkCancellation()
                guard generation == run else { return }
                // Credentials never go to a report, UserDefaults or stdout.
                let payload = try JSONSerialization.data(withJSONObject: account)
                stage = "storage"
                try await saveToKeychain(payload)
                self.pending = nil
                status.stringValue = "Conta autenticada. Tokens salvos nas Chaves do macOS. A inscrição no Cloud ainda está pendente."
                button.title = "Entrar novamente"; setBusy(false)
                recordSuccess()
                refreshProfile()
            } catch SamsungAccountWebProtocol.Failure.rejected(let statusCode, let reason) {
                guard generation == run else { return }
                let detail = reason.isEmpty ? "" : " · " + reason
                status.stringValue = "A Samsung recusou a autorização em \(stage) (HTTP \(statusCode)\(detail)). A sessão anterior foi preservada."
                writeResult(["account_flow": "windows_sso", "authorization_stage": stage, "authorization_http_status": statusCode,
                    "authorization_error_code": reason, "authorization_identifier_present": true])
                setBusy(false)
            } catch SamsungAccountContinuityProtocol.Failure.missingUsername {
                guard generation == run else { return }
                status.stringValue = "O retorno da Samsung não trouxe a identificação necessária para autorizar a continuidade. A sessão anterior foi preservada."
                writeResult(["account_flow": "windows_sso", "authorization_stage": stage,
                    "callback_username_present": false, "authorization_completed": false])
                setBusy(false)
            } catch SamsungAccountContinuityProtocol.Failure.consentRequired {
                guard generation == run else { return }
                status.stringValue = "A Samsung exige uma autorização adicional para o Cloud. A sessão anterior foi preservada."
                writeResult(["account_flow": "windows_sso", "authorization_stage": stage, "additional_consent_required": true])
                setBusy(false)
            } catch {
                guard generation == run else { return }
                status.stringValue = "A autorização não pôde ser concluída em \(stage). A sessão anterior foi preservada."
                writeResult(["account_flow": "windows_sso", "authorization_stage": stage, "authorization_completed": false])
                setBusy(false)
            }
    }

    private func saveToKeychain(_ data: Data, accountName: String = "samsung-account-web") async throws {
        let service = keychainService
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.writeCredential(data, service: service, accountName: accountName) })
            }
        }
    }

    nonisolated private static func writeCredential(_ data: Data, service: String, accountName: String) throws {
        let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: accountName]
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(update)) }
        var add = identity
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private func loadAccount(accountName: String = "samsung-account-web") async throws -> [String: Any] {
        let service = keychainService
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try Self.readCredential(service: service, accountName: accountName) })
            }
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SamsungCloudProtocol.Failure.missingAccount }
        return object
    }

    nonisolated private static func readCredential(service: String, accountName: String) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: accountName,
            kSecUseOperationPrompt as String: "Usar a sessão Samsung salva para continuar a conexão com o Cloud.",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw SamsungCloudProtocol.Failure.missingAccount }
        return data
    }

    @objc private func connectCloud() {
        cancelSignIn()
        let run = UUID(); generation = run
        setBusy(true); status.stringValue = "Verificando a sessão para conectar ao Cloud…"
        work = Task { [self] in
            var registered = false
            var stage = "keychain"
            var refreshed = false
            do {
                var account: [String: Any]
                if let saved = try? await loadAccount(), saved["client_id"] as? String == SamsungCloudProtocol.appID {
                    account = saved
                } else {
                    stage = "cloud_account_token"
                    let root = try await loadAccount(accountName: "samsung-account-root")
                    guard let userAuth = root["root_account_session"] as? [String: Any],
                          let auth = root["auth_host"] as? String, let api = root["api_host"] as? String,
                          let installation = root["installation_id"] as? String else { throw SamsungCloudProtocol.Failure.missingAccount }
                    let servers = try SamsungAccountProtocol.Servers.decode(JSONSerialization.data(withJSONObject: [
                        "auth_server_url": auth, "api_server_url": api, "idm_server_url": "account.samsung.com"]))
                    account = try await SamsungAccountContinuityProtocol.acquireCloudAccount(userAuth: userAuth,
                        servers: servers, installationID: installation)
                    try Task.checkCancellation()
                    guard generation == run else { return }
                    try await saveToKeychain(JSONSerialization.data(withJSONObject: account))
                }
                try Task.checkCancellation()
                guard generation == run else { return }
                stage = "token_refresh"
                status.stringValue = "Renovando a sessão Samsung antes de conectar ao Cloud…"
                account = try await SamsungAccountWebProtocol.refresh(account: account)
                // A rotated refresh token must be persisted before proceeding.
                try await saveToKeychain(JSONSerialization.data(withJSONObject: account))
                refreshed = true
                try Task.checkCancellation()
                guard generation == run else { return }
                guard let identifier = account["installation_id"] as? String else { throw SamsungCloudProtocol.Failure.missingAccount }
                let profile = SamsungCloudProtocol.Profile(installationID: identifier)
                stage = "discovery"
                let directory = try await SamsungCloudProtocol.discover(profile: profile)
                try Task.checkCancellation()
                guard generation == run else { return }
                status.stringValue = "Registrando o Mac no Cloud com o perfil de compatibilidade…"
                stage = "registration"
                let registration = try await SamsungCloudProtocol.register(account: account, profile: profile, directory: directory)
                registered = true
                try Task.checkCancellation()
                guard generation == run else { return }
                account["cloud_registration"] = try JSONSerialization.jsonObject(with: registration)
                account["cloud_registered_at"] = Date().timeIntervalSince1970
                stage = "storage"
                try await saveToKeychain(JSONSerialization.data(withJSONObject: account))
                recordSuccess(cloudEnrolled: true)
                connected = true; cloudEnrolled = true
                status.stringValue = "Conta conectada. Mac registrado no Samsung Cloud."
                setBusy(false)
            } catch SamsungCloudProtocol.Failure.rejected(let code, let reason) {
                guard generation == run else { return }
                let detail = reason.isEmpty ? "" : " · " + reason
                status.stringValue = "O Cloud recusou o pedido (HTTP \(code)\(detail)). O login da conta continua salvo."
                recordCloudFailure(http: code, code: reason, registered: registered, stage: stage, refreshed: refreshed)
                setBusy(false)
            } catch SamsungAccountWebProtocol.Failure.rejected(let code, let reason) {
                guard generation == run else { return }
                status.stringValue = "A Samsung recusou renovar a sessão (HTTP \(code)). Entre novamente para continuar."
                recordCloudFailure(http: code, code: reason, registered: false, stage: stage, refreshed: refreshed)
                setBusy(false)
            } catch SamsungCloudProtocol.Failure.missingAccount {
                guard generation == run else { return }
                status.stringValue = "A sessão salva não contém a identificação exigida pelo Cloud. Entre novamente para continuar."
                recordCloudFailure(http: 0, code: "MISSING_ACCOUNT_FIELDS", registered: registered, stage: stage, refreshed: refreshed)
                setBusy(false)
            } catch {
                guard generation == run else { return }
                status.stringValue = registered ? "Cloud registrado, mas não foi possível salvar sua sessão nas Chaves."
                    : "Não foi possível concluir o registro no Cloud. O login da conta continua salvo."
                recordCloudFailure(http: 0, code: "LOCAL_OR_TRANSPORT_FAILURE", registered: registered, stage: stage, refreshed: refreshed)
                setBusy(false)
            }
        }
    }

    /// Emits field names only when independently present in the shipped native
    /// client. Unknown/dynamic keys and every leaf value remain redacted.
    private func inspectBluetoothSchema() {
        cancelSignIn()
        let run = UUID(); generation = run
        setBusy(true)
        work = Task { [self] in
            do {
                let object = try await loadAccount(accountName: "bluetooth-cloud-documents")
                guard let evidencePath = ProcessInfo.processInfo.environment["BUDS_BLUETOOTH_SCHEMA_EVIDENCE"],
                      evidencePath.hasPrefix("/") else {
                    throw NSError(domain: "BudsAccount", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Arquivo de referência não configurado."])
                }
                let evidence = try Data(contentsOf: URL(fileURLWithPath: evidencePath))
                var shape: [String] = []
                func walk(_ value: Any, _ path: String, _ depth: Int) {
                    guard depth <= 7, shape.count < 150 else { return }
                    if let object = value as? [String: Any] {
                        for key in object.keys.sorted() {
                            let safe = key.range(of: "^[A-Za-z_][A-Za-z0-9_]{1,63}\\z", options: .regularExpression) != nil
                                && (evidence.range(of: Data(key.utf8)) != nil || evidence.range(of: key.data(using: .utf16LittleEndian)!) != nil)
                            walk(object[key]!, path + "." + (safe ? key : "<redacted-field>"), depth + 1)
                        }
                    } else if let array = value as? [Any] {
                        shape.append(path + ":array(\(array.count))")
                        for item in array.prefix(3) { walk(item, path + "[]", depth + 1) }
                    } else if let string = value as? String {
                        shape.append(path + ":string(\(string.utf8.count))")
                        if string.first == "{" || string.first == "[", let json = try? JSONSerialization.jsonObject(with: Data(string.utf8)) {
                            walk(json, path + ".$json", depth + 1)
                        }
                    } else { shape.append(path + ":scalar") }
                }
                walk(object, "$", 0)
                guard generation == run else { return }
                writeResult(["account_authenticated": true, "credentials_in_keychain": true,
                    "cloud_enrolled": true, "bluetooth_read": true, "bluetooth_schema": shape,
                    "native_switch_validated": false])
                status.stringValue = "Estrutura Bluetooth verificada. Os valores continuam protegidos nas Chaves."
                setBusy(false)
            } catch {
                guard generation == run else { return }
                status.stringValue = "Não foi possível verificar a estrutura Bluetooth salva."
                setBusy(false)
            }
        }
    }

    private func refreshProfile() {
        let run = generation
        profileWork = Task { [self] in
            defer { if CommandLine.arguments.contains("--profile-only") { NSApp.terminate(nil) } }
            do {
                let account = try await loadAccount()
                guard generation == run else { return }
                connected = true
                cloudEnrolled = account["cloud_registration"] != nil
                status.stringValue = "Conta salva neste Mac. Consultando seu perfil…"
                button.title = "Entrar novamente"
                var profile: SamsungAccountProfileProtocol.Profile
                var photoDiagnostic: [String: Any] = [:]
                do { profile = try await SamsungAccountProfileProtocol.fetch(account: account) }
                catch SamsungAccountProfileProtocol.Failure.rejected(406, _) {
                    profile = try await SamsungAccountProfileProtocol.fetchCloudAvatar(account: account)
                }
                catch SamsungAccountProfileProtocol.Failure.rejected(403, _) {
                    // The Account profile audience is distinct from the Cloud client.
                    let root = try await loadAccount(accountName: "samsung-account-root")
                    guard let userAuth = root["root_account_session"] as? [String: Any],
                          let auth = root["auth_host"] as? String, let api = root["api_host"] as? String,
                          let installation = root["installation_id"] as? String else { throw SamsungCloudProtocol.Failure.missingAccount }
                    let servers = try SamsungAccountProtocol.Servers.decode(JSONSerialization.data(withJSONObject: [
                        "auth_server_url": auth, "api_server_url": api, "idm_server_url": "account.samsung.com"]))
                    let profileAccount = try await SamsungAccountContinuityProtocol.acquireCloudAccount(userAuth: userAuth,
                        servers: servers, installationID: installation, consumer: .profile)
                    try await saveToKeychain(JSONSerialization.data(withJSONObject: profileAccount), accountName: "samsung-account-profile-session")
                    profile = try await SamsungAccountProfileProtocol.fetch(account: profileAccount)
                }
                if profile.avatar == nil, account["cloud_registration"] != nil {
                    do {
                        let photo = try await SamsungAccountProfileProtocol.fetchCloudAvatar(account: account)
                        profile = .init(name: profile.name, email: profile.email, avatar: photo.avatar)
                        photoDiagnostic["cloud_photo_loaded"] = photo.avatar != nil
                    } catch SamsungCloudProtocol.Failure.rejected(let http, let code) {
                        photoDiagnostic["cloud_photo_http"] = http; photoDiagnostic["cloud_photo_error"] = code
                    } catch { photoDiagnostic["cloud_photo_loaded"] = false }
                }
                guard generation == run, !Task.isCancelled else { return }
                if let name = profile.name {
                    profileName.stringValue = name
                    profileInitials.stringValue = name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined().uppercased()
                }
                if let data = profile.avatar, let image = NSImage(data: data) {
                    profileImage.image = image; profileInitials.isHidden = true
                    avatarBase64 = data.base64EncodedString()
                    avatarRevision += 1
                }
                var privateProfile: [String: Any] = [:]
                privateProfile["name"] = profile.name; privateProfile["email"] = profile.email
                privateProfile["avatar_base64"] = profile.avatar?.base64EncodedString()
                try await saveToKeychain(JSONSerialization.data(withJSONObject: privateProfile), accountName: "samsung-account-profile")
                writeProfileResult(photoDiagnostic.merging(["profile_loaded": true, "profile_has_name": profile.name != nil, "profile_has_avatar": profile.avatar != nil]) { _, new in new })
                if account["cloud_registration"] != nil { status.stringValue = "Conta conectada. Mac registrado no Samsung Cloud." }
                else { status.stringValue = "Conta conectada. Sincronize seus dispositivos para continuar." }
            } catch SamsungAccountProfileProtocol.Failure.rejected(let http, let code) {
                guard generation == run else { return }
                status.stringValue = "Conta salva. A foto do perfil não está disponível nesta sessão."
                writeProfileResult(["profile_loaded": false, "profile_http_status": http, "profile_error_code": code])
            } catch {
                writeProfileResult(["profile_loaded": false, "profile_http_status": 0])
            }
        }
    }

    private func writeProfileResult(_ values: [String: Any]) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GalaxyBudsAccountResearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = values; values["timestamp"] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: values) {
            try? data.write(to: directory.appendingPathComponent("profile-result.json"), options: .atomic)
        }
    }

    private func readBluetooth() {
        cancelSignIn()
        let run = UUID(); generation = run
        setBusy(true); status.stringValue = "Verificando os registros Bluetooth no Cloud…"
        work = Task { [self] in
            var stage = "keychain"
            do {
                let account = try await loadAccount()
                guard let identifier = account["installation_id"] as? String else { throw SamsungCloudProtocol.Failure.missingAccount }
                let profile = SamsungCloudProtocol.Profile(installationID: identifier)
                stage = "discovery"
                let directory = try await SamsungCloudProtocol.discover(profile: profile)
                try Task.checkCancellation()
                guard generation == run else { return }
                stage = "bluetooth_documents_v3"
                let snapshot = try await SamsungCloudProtocol.readBluetoothDocuments(account: account, directory: directory, profile: profile)
                try Task.checkCancellation()
                guard generation == run else { return }
                stage = "storage"
                try await saveToKeychain(snapshot.data, accountName: "bluetooth-cloud-documents")
                writeResult(["account_authenticated": true, "credentials_in_keychain": true,
                    "cloud_enrolled": true, "bluetooth_read": true, "bluetooth_document_count": snapshot.count,
                    "bluetooth_encrypted_count": snapshot.encryptedCount, "bluetooth_has_next": snapshot.hasNext,
                    "native_switch_validated": false])
                status.stringValue = "Cloud acessível: \(snapshot.count) registros Bluetooth recebidos. A troca de áudio ainda precisa ser validada."
                setBusy(false)
            } catch SamsungCloudProtocol.Failure.rejected(let http, let reason) {
                guard generation == run else { return }
                recordCloudFailure(http: http, code: reason, registered: true, stage: stage, refreshed: false)
                status.stringValue = "O Cloud recusou a leitura Bluetooth (HTTP \(http) · \(reason)). O registro da conta continua salvo."
                setBusy(false)
            } catch {
                guard generation == run else { return }
                recordCloudFailure(http: 0, code: "LOCAL_OR_RESPONSE_FAILURE", registered: true, stage: stage, refreshed: false)
                status.stringValue = "A leitura Bluetooth não foi concluída. O registro da conta continua salvo."
                setBusy(false)
            }
        }
    }

    private func recordCloudFailure(http: Int, code: String, registered: Bool, stage: String, refreshed: Bool) {
        writeResult(["account_authenticated": true, "credentials_in_keychain": true,
            "cloud_enrolled": registered, "bluetooth_read": false, "cloud_http_status": http,
            "cloud_error_code": code, "cloud_stage": stage, "account_token_refreshed": refreshed,
            "native_switch_validated": false])
    }

    private func recordSuccess(cloudEnrolled: Bool = false, bluetoothRead: Bool = false) {
        writeResult(["account_authenticated": true, "credentials_in_keychain": true,
            "cloud_enrolled": cloudEnrolled, "bluetooth_read": bluetoothRead, "native_switch_validated": false])
    }

    private func writeResult(_ values: [String: Any]) {
        // Only booleans/timestamp; this never includes a URL, account ID or token.
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GalaxyBudsAccountResearch", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var summary = callbackDiagnostics.mapValues { $0 as Any }.merging(values) { _, new in new }
        // Identity registration remains cloud_enrolled for compatibility; it
        // cannot imply certificate provisioning or peer handshake validation.
        let certificateState = certificateDiagnostics.publicValues.mapValues { $0 as Any }
        summary = certificateState.merging(summary) { _, new in new }
        if values["cloud_identity_registered"] == nil {
            summary["cloud_identity_registered"] = values["cloud_enrolled"] ?? cloudEnrolled
        }
        summary["peer_authenticated"] = false
        summary["timestamp"] = Date().timeIntervalSince1970
        if let data = try? JSONSerialization.data(withJSONObject: summary) {
            try? data.write(to: directory.appendingPathComponent("last-result.json"), options: .atomic)
        }
    }
}

#if !BUDS_EMBEDDED
@main
struct AccountSignInProbe {
    @MainActor static func main() {
        let application = NSApplication.shared
        let controller = AccountSignInController()
        application.setActivationPolicy(CommandLine.arguments.contains("--profile-only") ? .accessory : .regular)
        application.delegate = controller
        withExtendedLifetime(controller) { application.run() }
    }
}

#endif
