#if BUDS_EMBEDDED
import AppKit
import SwiftUI

/// Shared backend for the native menu-bar panel and managed lifecycle host.
@MainActor private enum BudsNativeSession {
    static var account: AccountSignInController?
    static var switchModel: NativeAutoSwitchModel?
    static var peerCoordinator: NativeSamsungPeerCoordinator?
    static var settingsModel: NativeBudsSettingsModel?
    static var preparing = false
    static var connectionMonitor: NativeBudsConnectionMonitor?
    static var physicalLink: (address: String, connected: Bool)?
    static var monitoredAddress = ""
    static var settingsAcquisition: UUID?
    static var connectionEpoch: UUID?
    static var panelOpen = false
    static var panelEpoch: UUID?
    static var updateQuiescing = false
    static var updateWasEnabled = false
    static var updateResumeTask: Task<Void, Never>?
    static var updateTerminationTask: Task<Void, Never>?
    static var updateTerminationReady = false
    static var managedCallback: (@convention(c) (UnsafePointer<CChar>?) -> Void)?
    static var appUpdater: NativeAppUpdater?
    static let firmwareCatalog = NativeBudsFirmwareCatalog()
    static let volume = NativeBudsVolume(permission: {
        .init(selectedAddress: switchModel?.selectedBuds ?? "",
            canSet: !preparing && switchModel?.canSetVolume == true && settingsModel?.busy != true)
    })

    static func prepare() {
        if account == nil {
            let controller = AccountSignInController(embedded: true)
            account = controller
            controller.onContinuityReady = {
                guard let peer = BudsNativeSession.peerCoordinator else { return }
                if let model = BudsNativeSession.switchModel, model.enabled {
                    peer.connectSelected()
                    model.refreshPeerOwnershipAnnouncement()
                } else { peer.refreshRoster() }
            }
            controller.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        }
        if switchModel == nil {
            let model = NativeAutoSwitchModel()
            switchModel = model
            let peer = NativeSamsungPeerCoordinator.live(materialProvider: {
                guard let account = BudsNativeSession.account else {
                    throw NativeSamsungPeerCoordinatorDiagnostics.Failure.materialUnavailable
                }
                return try await account.preparedOutgoingPeerMaterial()
            }, budsContextProvider: { [weak model] in model?.ownedContinuityBudsContext })
            peerCoordinator = peer
            #if DEBUG
            // Explicit laboratory A/B; no registry, OS identity, pairing or
            // firmware change. Release retains the measured PC profile.
            model.laboratoryMobileMDEProfile = UserDefaults.standard.bool(forKey: "BudsLaboratoryMobileMDEProfile")
            model.laboratoryMDEVersion2 = UserDefaults.standard.bool(forKey: "BudsLaboratoryMDEVersion2")
            model.laboratoryAndroidMetadataRequest = UserDefaults.standard.bool(forKey: "BudsLaboratoryAndroidMetadataRequest")
            model.laboratoryCooperativeForegroundRejection = ProcessInfo.processInfo.environment["BUDS_VERIFY_COOPERATIVE_FOREGROUND_REJECTION"] == "1"
            model.laboratoryPlaybackReports = ProcessInfo.processInfo.environment["BUDS_VERIFY_PLAYBACK_REPORTS"] == "1"
            model.laboratoryProvisionalRouteRelease = ProcessInfo.processInfo.environment["BUDS_VERIFY_PROVISIONAL_ROUTE_RELEASE"] == "1"
            if UserDefaults.standard.bool(forKey: "BudsLaboratoryOwnedAccountMDE") {
                model.ownedMDEConfiguration = { [weak peer] in
                    guard let peer else { throw NativeSamsungPeerCoordinatorDiagnostics.Failure.materialUnavailable }
                    return try await peer.ownedMDEConfiguration()
                }
            }
            #endif
            peer.onRemoteReady = { [weak model] epoch, address in
                model?.requestYieldForAuthenticatedReady(epoch: epoch, budsAddress: address)
            }
            peer.onRoster = { [weak model] phones, selected in
                model?.phones = phones; model?.selectedPhone = selected
            }
            model.onMacAcquired = { [weak peer] epoch, address in
                BudsNativeSession.settingsAcquisition = epoch
                peer?.start()
                peer?.acquiredMac(epoch: epoch, budsAddress: address)
            }
            model.onMacOwnershipLost = { [weak peer] in
                BudsNativeSession.settingsAcquisition = nil
                BudsNativeSession.settingsModel?.cancel()
                peer?.lostMac()
            }
            model.onMacYieldPrepared = { [weak peer] epoch, address in peer?.macYieldPrepared(epoch: epoch, budsAddress: address) }
            model.onLocalPlaybackIntent = { [weak peer] in
                BudsNativeSession.settingsModel?.cancel()
                peer?.localPlaybackResumed()
            }
            // Enabling account continuity establishes its selected phone session
            // before playback. Authentication alone never requests Buds audio.
            model.onPeerLifecycle = { [weak peer] active in if active { peer?.connectSelected() } else { peer?.stop() } }
            model.peerDiagnostics = { [weak peer] in peer?.publicDiagnostics ?? [:] }
            Task { await model.refresh(); synchronizeSettings() }
        }
        if appUpdater == nil {
            let updater = NativeAppUpdater(isSafeToInstall: { safeForAppUpdate() }, requestGracefulShutdown: {
                await prepareAppUpdateShutdown()
            })
            appUpdater = updater
            updater.onChange = { resumeAfterCancelledAppUpdate() }
            updater.start()
        }
        if settingsModel == nil { settingsModel = NativeBudsSettingsModel(environment: .live(toolsPermission: { toolsPermitted() })) }
        ConnectionHUD.shared.batteryProvider = { address in
            guard let model = BudsNativeSession.switchModel,
                  BudsBatterySnapshot.normalize(address) == BudsBatterySnapshot.normalize(model.selectedBuds) else { return nil }
            return BudsBatterySnapshot.newestCurrent([BudsNativeSession.settingsModel?.batterySnapshot,
                model.batterySnapshot], address: address)
        }
        synchronizeSettings()
    }

    private static func selectedBattery(_ model: NativeAutoSwitchModel) -> BudsBatterySnapshot? {
        [settingsModel?.batterySnapshot, model.batterySnapshot,
         BudsBatterySnapshot.loadCached(address: model.selectedBuds)]
            .compactMap { $0 }.filter { $0.isFor(address: model.selectedBuds) }
            .max { $0.observedAt < $1.observedAt }
    }
    private static func settingsOperationsDrained() -> Bool {
        let diagnostics = settingsModel?.snapshot["transport_diagnostics"] as? [String: Any]
        return NativeBudsOperationDrain.shared.count == 0
            && (diagnostics?["pending_operations"] as? Int ?? 0) == 0
            && settingsModel?.busy != true
    }

    private static func safeForAppUpdate() -> Bool {
        guard let activity = try? MacAudio.activity(), !activity.input, !activity.output else { return false }
        return !preparing && switchModel?.busy != true && switchModel?.transportIsSettling != true
            && switchModel?.recoveryPending != true && switchModel?.remoteCallActive != true
            && settingsModel?.toolInProgress != true
            && settingsOperationsDrained()
    }

    private static func prepareAppUpdateShutdown() async {
        updateResumeTask?.cancel(); updateResumeTask = nil
        if !updateQuiescing {
            updateWasEnabled = switchModel?.enabled == true
            updateQuiescing = true
        }
        settingsModel?.cancel()
        peerCoordinator?.stop()
        switchModel?.stop()
        while !Task.isCancelled {
            if switchModel?.enabled != true, switchModel?.busy != true,
               switchModel?.transportIsSettling != true, switchModel?.recoveryPending != true,
               settingsOperationsDrained() { return }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        }
    }

    private static func resumeAfterCancelledAppUpdate() {
        guard updateQuiescing, let status = appUpdater?.snapshot["status"] as? String,
              ["error", "cancelled", "no_update", "check_finished"].contains(status) else { return }
        resumeAfterAppUpdate()
    }

    private static func resumeAfterAppUpdate() {
        updateQuiescing = false
        updateTerminationReady = false
        updateTerminationTask?.cancel(); updateTerminationTask = nil
        let shouldResume = updateWasEnabled
        updateWasEnabled = false
        guard shouldResume, UserDefaults.standard.object(forKey: "BudsNativeAutoSwitchEnabled") as? Bool ?? true else { return }
        updateResumeTask?.cancel()
        updateResumeTask = Task { @MainActor in
            while !Task.isCancelled {
                guard !updateQuiescing,
                      UserDefaults.standard.object(forKey: "BudsNativeAutoSwitchEnabled") as? Bool ?? true else { return }
                if switchModel?.enabled == true { return }
                if !preparing, switchModel?.busy != true, switchModel?.transportIsSettling != true,
                   switchModel?.remoteCallActive != true,
                   (try? MacAudio.activity().input) == false, settingsOperationsDrained(), switchModel?.recoveryPending != true {
                    "{\"action\":\"switch.start\"}".withCString { managedCallback?($0) }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    static func prepareUpdateTermination() -> Int32 {
        guard appUpdater?.requiresSafeTermination == true else { return 1 }
        if updateTerminationReady && safeForAppUpdate() { return 1 }
        if updateTerminationTask == nil {
            updateTerminationTask = Task { @MainActor in
                updateTerminationReady = await appUpdater?.prepareForTermination() == true
                updateTerminationTask = nil
            }
        }
        return 0
    }

    static func cancelUpdateTermination() {
        updateTerminationTask?.cancel(); updateTerminationTask = nil
        updateTerminationReady = false
        if updateQuiescing, appUpdater?.postponingInstallation != true { resumeAfterAppUpdate() }
    }

    private static func toolsPermitted() -> Bool {
        !preparing && !updateQuiescing && switchModel?.canUseSettingsTools == true && (try? MacAudio.activity().input) == false
    }

    /// Selection/configuration updates are purely local. Snapshot polling never
    /// calls settings refresh, connection checks or RFCOMM open.
    private static func synchronizeSettings() {
        guard let model = switchModel, let settingsModel else { return }
        let peer = model.buds.first { $0.address == model.selectedBuds }
        let battery = selectedBattery(model)
        let cached = BudsBatterySnapshot.loadCached(address: model.selectedBuds)
        let knownModel = battery?.model.isEmpty == false ? battery?.model : cached?.model
        let profile = NativeBudsProfile.resolve(model: knownModel, name: peer?.name ?? battery?.name ?? "")
        if connectionMonitor == nil {
            connectionMonitor = .live(onEvent: { ConnectionHUD.shared.show(event: $0) },
                onLinkState: { address, connected, at in
                    physicalLink = (address, connected)
                    connectionEpoch = connected ? UUID() : nil
                    if !connected {
                        BudsNativeSession.settingsAcquisition = nil
                        BudsNativeSession.settingsModel?.invalidateConnection()
                    }
                    ConnectionHUD.shared.observeLink(address: address, connected: connected, at: at)
                })
        }
        let address = BudsBatterySnapshot.normalize(model.selectedBuds)
        if monitoredAddress != address { physicalLink = nil; connectionEpoch = nil; monitoredAddress = address }
        connectionMonitor?.select(address: model.selectedBuds, name: peer?.name ?? battery?.name ?? "Galaxy Buds")
        settingsModel.releaseAfterTransaction = model.enabled
        settingsModel.select(address: peer?.address ?? "", name: peer?.name ?? "",
            model: profile.model,
            // The shared drain also counts this settings model's pending open.
            // Polling must not cancel that operation as if it belonged to switch.
            blocked: preparing || updateQuiescing || !model.canInspectSettings
                || (settingsModel.toolInProgress && !toolsPermitted())
                || (model.transportIsSettling && !settingsModel.busy) || model.recoveryPending,
            connectionEpoch: connectionEpoch)
        firmwareCatalog.select(address: model.selectedBuds, model: profile.model,
            installed: model.firmwareVersion ?? (settingsModel.snapshot["firmware_version"] as? String))
    }

    static func snapshot(avatarRevision: Int) -> String {
        prepare()
        guard let account, let model = switchModel else { return "{}" }
        let battery = selectedBattery(model)
        let cached = BudsBatterySnapshot.loadCached(address: model.selectedBuds)
        let name = model.buds.first { $0.address == model.selectedBuds }?.name ?? battery?.name
        let knownModel = battery?.model.isEmpty == false ? battery?.model : cached?.model
        let profile = NativeBudsProfile.resolve(model: knownModel, name: name ?? "")
        let artwork = profile.artwork(battery?.iconPrefix) ?? (cached?.model == profile.model ? profile.artwork(cached?.iconPrefix) : nil)
        var metadata = profile.fields
        metadata["icon_prefix"] = profile.artwork(artwork) as Any? ?? NSNull()
        metadata["connection_epoch"] = connectionEpoch?.uuidString as Any? ?? NSNull()
        metadata["existing_mac_settings_route"] = model.hasExistingMacSettingsRoute
        metadata["audio_endpoint_present"] = NativeBudsAudioPresence.read(address: model.selectedBuds) as Any? ?? NSNull()
        metadata["bluetooth_connected"] = physicalLink.flatMap {
            BudsBatterySnapshot.normalize($0.address) == BudsBatterySnapshot.normalize(model.selectedBuds) ? $0.connected : nil
        } as Any? ?? NSNull()
        var accountState = account.embeddedState(knownAvatarRevision: avatarRevision)
        var deviceState = settingsModel?.snapshot ?? [:]
        if let version = model.firmwareVersion, let date = model.firmwareObservedAt {
            deviceState["firmware_version"] = version
            deviceState["firmware_observed_at"] = date.timeIntervalSince1970
        }
        // Certificate readiness cannot overwrite actual peer session evidence.
        accountState["peer_authenticated"] = peerCoordinator?.diagnostics.authenticated ?? false
        let state: [String: Any] = [
            "visible_application_windows": NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count,
            "account": accountState,
            "preferences": ["auto_switch_enabled": UserDefaults.standard.object(forKey: "BudsNativeAutoSwitchEnabled") as? Bool ?? true],
            "presentation": ["panel_open": panelOpen, "panel_epoch": panelEpoch?.uuidString as Any? ?? NSNull()],
            "app_update": appUpdater?.snapshot ?? [:],
            "firmware_update": firmwareCatalog.snapshot,
            "device_metadata": metadata,
            "device": deviceState,
            "volume": volume.snapshot,
            "switching": ["transport": "native", "starting": preparing, "enabled": model.enabled, "busy": model.busy || model.transportIsSettling, "ready": model.ready,
                "device_name": name.map { $0 as Any } ?? NSNull(),
                "settings_epoch": settingsAcquisition?.uuidString as Any? ?? NSNull(),
                "battery": battery.map { $0.panelFields as Any } ?? NSNull(),
                "settling": model.transportIsSettling,
                "build_id": Bundle.main.object(forInfoDictionaryKey: "BudsBuildIdentifier") as? String ?? "development",
                "configuration": Bundle.main.object(forInfoDictionaryKey: "BudsBuildConfiguration") as? String ?? "development",
                "wait_silently": model.waitSilently,
                "status": model.transportIsSettling ? "Cancelamento solicitado. Aguardando o Bluetooth concluir a operação pendente…" : model.status,
                "error": model.error ?? "",
                "selected_buds": model.selectedBuds, "selected_phone": model.selectedPhone,
                "buds": model.buds.map { ["id": $0.address, "name": $0.name] },
                "phones": model.phones.map { ["id": $0.id, "name": $0.name] },
                "mac_activity": model.macActivity, "phone_activity": model.phoneActivity,
                "detection": model.playbackDetection, "route": model.route,
                "protocol_status_updates": model.protocolStatusUpdates, "native_channel_open": model.nativeChannelOpen,
                "transport_diagnostics": model.transportDiagnostics,
                "multipoint_state": model.multipointState, "stream_flags": model.streamFlags,
                "recovery_pending": model.recoveryPending]]
        guard let data = try? JSONSerialization.data(withJSONObject: state), let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }

    static func perform(_ request: [String: Any]) {
        prepare()
        guard let action = request["action"] as? String, let model = switchModel else { return }
        if action.hasPrefix("app.update_") { appUpdater?.perform(request: request); return }
        if updateQuiescing && action != "ui.panel_visibility" && action != "switch.stop" { return }
        if action == "firmware.check" {
            synchronizeSettings()
            firmwareCatalog.refresh()
            return
        }
        if action == "ui.panel_visibility", let open = request["open"] as? Bool {
            if open && !panelOpen { panelEpoch = UUID() }
            panelOpen = open
            if !open { settingsModel?.cancel() }
            return
        }
        if action == "account.peer_connect" {
            peerCoordinator?.connectSelected(); return
        }
        if action == "account.peer_refresh" {
            peerCoordinator?.refreshRoster(); return
        }
        if action.hasPrefix("account.") {
            peerCoordinator?.stop(accountChanged: true)
            account?.embeddedAction(String(action.dropFirst(8)), identity: request["identity"] as? String ?? "")
            return
        }
        if action == "device.volume" {
            volume.perform(level: request["level"])
            return
        }
        if action.hasPrefix("device.") {
            synchronizeSettings()
            if action == "device.refresh", let settingsModel {
                let snapshot = settingsModel.snapshot
                let observed = snapshot["observed_at"] as? Double
                if snapshot["busy"] as? Bool == false, observed.map({ Date().timeIntervalSince1970 - $0 > 12 }) == true {
                    // A refresh must obtain a new bootstrap rather than replay
                    // an old gesture bitfield as if it had just been received.
                    settingsModel.cancel()
                    synchronizeSettings()
                }
            }
            settingsModel?.perform(request)
            return
        }
        switch action {
        #if DEBUG
        case "laboratory.phone_intent_yield":
            model.laboratoryYieldForObservedPhoneIntent()
        #endif
        case "switch.refresh":
            settingsModel?.suspend()
            peerCoordinator?.refreshRoster()
            Task { await model.refresh(); synchronizeSettings() }
        case "switch.preparing":
            settingsModel?.cancel()
            preparing = true; model.status = "Preparando a conexão nativa dos Buds…"
        case "switch.cancelled": preparing = false; model.status = "Conexão cancelada."
        case "switch.failure":
            preparing = false
            // Lifecycle state belongs to the model. Directly clearing enabled
            // could abandon an active guard/channel without running cleanup.
            model.stop()
            model.error = request["error"] as? String ?? "Não foi possível preparar a conexão. Tente novamente."
        case "switch.start":
            UserDefaults.standard.set(true, forKey: "BudsNativeAutoSwitchEnabled")
            settingsModel?.suspend()
            preparing = false
            guard account?.embeddedState(knownAvatarRevision: 0)["cloud_enrolled"] as? Bool == true else {
                model.error = "Conecte sua Samsung Account e conclua o registro do Mac antes de ativar a alternância."
                return
            }
            model.start(transportGranted: request["transport_granted"] as? Bool == true)
        case "switch.stop":
            UserDefaults.standard.set(false, forKey: "BudsNativeAutoSwitchEnabled")
            peerCoordinator?.stop()
            if preparing && !model.enabled { model.status = "Conexão cancelada." }
            preparing = false
            model.stop()
        case "switch.configure":
            guard !model.enabled, !model.busy, !model.transportIsSettling, !model.recoveryPending else { return }
            settingsModel?.cancel()
            if let buds = request["buds"] as? String, model.buds.contains(where: { $0.address == buds }), buds != model.selectedBuds {
                model.selectedBuds = buds; model.configurationChanged()
            }
            if let phone = request["phone"] as? String, model.phones.contains(where: { $0.id == phone }), phone != model.selectedPhone {
                peerCoordinator?.selectPhone(phone)
                model.selectedPhone = phone
            }
        default: break
        }
        synchronizeSettings()
    }
}

@_cdecl("buds_switch_is_active")
public func budsSwitchIsActive() -> Int32 {
    let read = { MainActor.assumeIsolated { () -> Int32 in
        guard let model = BudsNativeSession.switchModel else { return 0 }
        return BudsNativeSession.preparing || model.enabled || model.busy || model.transportIsSettling ? 1 : 0
    } }
    return Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read)
}

@_cdecl("buds_copy_state")
public func budsCopyState(_ avatarRevision: Int32) -> UnsafeMutablePointer<CChar>? {
    let read = { MainActor.assumeIsolated { BudsNativeSession.snapshot(avatarRevision: Int(avatarRevision)) } }
    return strdup(Thread.isMainThread ? read() : DispatchQueue.main.sync(execute: read))
}

@_cdecl("buds_free_state")
public func budsFreeState(_ pointer: UnsafeMutablePointer<CChar>?) { free(pointer) }

@_cdecl("buds_perform_action")
public func budsPerformAction(_ json: UnsafePointer<CChar>?) {
    guard let json else { return }
    let text = String(cString: json)
    guard text.utf8.count <= 16_384, let data = text.data(using: .utf8),
          let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
    DispatchQueue.main.async { BudsNativeSession.perform(request) }
}

// Retain ABI compatibility, without spawning independent application windows.
@_cdecl("buds_open_account")
public func budsOpenAccount() { DispatchQueue.main.async { BudsNativeSession.prepare() } }

@_cdecl("buds_open_switch_settings")
public func budsOpenSwitchSettings(_ address: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?) {
    DispatchQueue.main.async { BudsNativeSession.prepare() }
}

@_cdecl("buds_show_connected")
public func budsShowConnected(_ address: UnsafePointer<CChar>?, _ name: UnsafePointer<CChar>?, _ galaxy: Int32) {
    guard let address else { return }
    let value = String(cString: address)
    let name = name.map(String.init(cString:)) ?? "Galaxy Buds"
    DispatchQueue.main.async { ConnectionHUD.shared.showConnected(address: value, name: name, galaxy: galaxy != 0) }
}

@_cdecl("buds_native_shutdown")
public func budsNativeShutdown() {
    DispatchQueue.main.async {
        BudsNativeSession.preparing = false
        BudsNativeSession.peerCoordinator?.stop()
        BudsNativeSession.connectionMonitor?.stop()
        BudsNativeSession.settingsModel?.cancel()
        BudsNativeSession.switchModel?.stop(); BudsNativeSession.account?.cancelPending()
    }
}

@_cdecl("buds_set_host_action_callback")
public func budsSetHostActionCallback(_ callback: (@convention(c) (UnsafePointer<CChar>?) -> Void)?) {
    DispatchQueue.main.async { BudsNativeSession.managedCallback = callback }
}

@_cdecl("buds_prepare_update_termination")
public func budsPrepareUpdateTermination() -> Int32 {
    if Thread.isMainThread { return MainActor.assumeIsolated { BudsNativeSession.prepareUpdateTermination() } }
    return DispatchQueue.main.sync { BudsNativeSession.prepareUpdateTermination() }
}

@_cdecl("buds_cancel_update_termination")
public func budsCancelUpdateTermination() {
    DispatchQueue.main.async { BudsNativeSession.cancelUpdateTermination() }
}
#endif
