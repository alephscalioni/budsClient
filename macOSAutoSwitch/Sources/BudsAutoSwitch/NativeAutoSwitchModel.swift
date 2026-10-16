import Foundation
import Combine
import AppKit

/// Native backend for the unified UI. The host must grant exclusive transport
/// ownership before start; creating/refreshing this model never enables it.
@MainActor final class NativeAutoSwitchModel: ObservableObject {
    @Published var phones: [PhoneDevice] = []
    @Published var buds: [(address: String, name: String)] = []
    @Published var selectedPhone = ""
    @Published var selectedBuds = ""
    @Published var enabled = false
    @Published var waitSilently = true
    @Published var busy = false
    @Published var ready = false
    @Published var status = "Verifique os Buds para começar."
    @Published var error: String?
    @Published var macActivity = "Sem leitura"
    @Published var playbackDetection = "Aguardando"
    @Published var phoneActivity = "Sem leitura"
    @Published var route = "Sem saída confirmada"
    let transport = "native"
    var protocolStatusUpdates: UInt64 { evidence.serial }
    var nativeChannelOpen: Bool { environment.isOpen() }
    var remoteCallActive: Bool { evidence.callActive }
    private var firmwareInfo: (address: String, version: String, date: Date)?
    var firmwareVersion: String? { firmwareInfo?.address == selectedBuds ? firmwareInfo?.version : nil }
    var firmwareObservedAt: Date? { firmwareInfo?.address == selectedBuds ? firmwareInfo?.date : nil }
    var canManageSettings: Bool {
        enabled && ownsMac && !requesting && !busy && !yieldRequired && pauseTask == nil
            && physicalRelease == nil && controlPrepared && environment.isOpen()
    }
    /// SppNew controls the connected accessory; reading its settings does not
    /// request A2DP ownership. Keep actual startup/handoff/recovery barriers.
    var canInspectSettings: Bool {
        !busy && !requesting && !draining && cleanup == nil && physicalRelease == nil
            && pauseTask == nil && !yieldRequired && !selectedBuds.isEmpty
    }
    /// Accessory tools use SppNew, independently of the selected audio output.
    var canUseSettingsTools: Bool { canInspectSettings && !recoveryPending && !evidence.callActive }
    /// Settings may inspect an already-selected Mac output without requesting
    /// ownership or interrupting playback that predates automatic switching.
    var hasExistingMacSettingsRoute: Bool {
        guard !busy, !requesting, !draining, cleanup == nil, physicalRelease == nil,
              pauseTask == nil, !yieldRequired, !evidence.callActive,
              !selectedBuds.isEmpty, let target = try? environment.output(selectedBuds) else { return false }
        if environment.isArmed() {
            guard controlPrepared, environment.isOpen(), evidence.status?.state == .foreground,
                  environment.armedDevice() != target else { return false }
        }
        return environment.defaultOutput() == target
    }
    /// Passive permission only; the volume controller separately verifies HAL.
    var canSetVolume: Bool {
        guard canManageSettings, !draining, cleanup == nil, pauseTask == nil, !yieldRequired,
              !evidence.callActive, !address.isEmpty, selectedBuds == address,
              buds.contains(where: { $0.address == address }),
              let target = try? environment.output(address), environment.defaultOutput() == target else { return false }
        // Continuity deliberately keeps the previous output protected while
        // the Buds play. That guard must not disable this different endpoint's
        // volume, or volume would remain unavailable throughout normal use.
        if environment.isArmed() {
            guard let protected = environment.armedDevice(), protected != target else { return false }
            do { try verifyGuard() } catch { return false }
        }
        return true
    }
    var transportDiagnostics: [String: Any] {
        var result = environment.diagnostics()
        result["peer"] = peerDiagnostics?() ?? [:]
        result["mde_profile"] = laboratoryMobileMDEProfile ? "mobile_compatibility" : "computer"
        result["mde_request_variant"] = laboratoryAndroidMetadataRequest ? "android_metadata_empty"
            : laboratoryMobileMDEProfile ? "windows_phone_2" : "windows_computer_1"
        result["mde_configuration_version"] = laboratoryMDEVersion2 ? 2 : 3
        result["cooperative_foreground_rejection"] = laboratoryCooperativeForegroundRejection
        result["playback_reports"] = laboratoryPlaybackReports
        result["provisional_route_release"] = laboratoryProvisionalRouteRelease
        result["mde_account_configuration_submitted"] = ownedMDEConfigured
        result["mde_account_echo_matches"] = ownedMDEEchoMatches.map { $0 as Any } ?? NSNull()
        result["mde_account_echo_status"] = ownedMDEEchoStatus.map { $0 as Any } ?? NSNull()
        result["control_prepared"] = controlPrepared
        result["controller_events"] = controllerEvents
        result["physical_release_pending"] = physicalRelease != nil
        result["physical_link_absent_observed"] = physicalLinkAbsent
        var contextReadiness = continuityEvidence.metadataReadiness(at: environment.now())
        contextReadiness["profile_source_available"] = environment.continuityProfiles != nil
        result["owned_buds_context"] = contextReadiness
        if let originalFailure { result["original_failure"] = originalFailure }
        return result
    }
    var transportIsSettling: Bool { draining || physicalRelease != nil || (!enabled && (transportDiagnostics["pending_operations"] as? Int ?? 0) > 0) }
    var multipointState: Int { evidence.status.map { Int($0.state.rawValue) } ?? -1 }
    var streamFlags: Int { evidence.status.map { Int($0.streamType.rawValue) } ?? -1 }
    var recoveryPending: Bool { environment.isArmed() && (!enabled || cleanup != nil || audioRecovery != nil) }

    private let environment: NativeSwitchEnvironment
    private var playbackStarted = false
    private var recovery = NativeSwitchRecoveryPolicy()
    private var stableSince: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0
    private var pendingLocalIntent: UInt64?
    private var acquisitionDeadline: TimeInterval?
    private var evidence = NativeSwitchEvidence()
    // Presentation only. Never used to authorize requests, routing, peer
    // responses, release or recovery. Retain the preceding remote proof through
    // an intentional ACL release; consume it on acquisition or session retirement.
    private var bannerRemoteOwnership = false
    private var continuityEvidence = NativeSamsungBudsContextEvidence()
    private var monitor: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var audioRecovery: Task<Void, Never>?
    private var draining = false
    private var pauseTask: Task<Void, Error>?
    private var switchDeadline: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var address = ""
    private var name = "Galaxy Buds"
    var onMacAcquired: ((UUID, String) -> Void)?
    var onMacOwnershipLost: (() -> Void)?
    var onPeerLifecycle: ((Bool) -> Void)?
    /// Emitted only after verified player pause and guarded waiting-route yield.
    var onMacYieldPrepared: ((UUID, String) -> Void)?
    var onLocalPlaybackIntent: (() -> Void)?
    var ownedMDEConfiguration: (() async throws -> Data)?
    var laboratoryMobileMDEProfile = false
    var laboratoryMDEVersion2 = false
    var laboratoryAndroidMetadataRequest = false
    /// Laboratory compatibility probe: foreground132 stays nonfatal and never
    /// establishes phone ownership. A single verified pause can release the
    /// active Mac stream; normal background/route evidence must finish the yield.
    var laboratoryCooperativeForegroundRejection = false
    var laboratoryPlaybackReports = false
    var laboratoryProvisionalRouteRelease = false
    private var cooperativePauseEpoch: UUID?
    private var playbackReport: SamsungMdePacket.PlaybackStatus?
    /// Evaluated synchronously for each peer write, including post-yield
    /// responses. Acquisition facts cannot advertise foreground after loss.
    var ownedContinuityBudsContext: SamsungContinuityBudsContext? {
        let token = generation
        guard enabled, ownsMac, controlPrepared, environment.isOpen(),
              let session = continuityEvidence.session,
              let source = environment.continuityProfiles else { return nil }
        let profiles = source(address, session)
        // An injected observer can synchronously retire or replace a session.
        guard active(token), continuityEvidence.session == session, ownsMac,
              controlPrepared, environment.isOpen(), evidence.status?.state == .foreground,
              profiles?.hfp != .audioActive,
              evidence.status?.streamType.rawValue == 1,
              let target = try? environment.output(address), environment.defaultOutput() == target else { return nil }
        do { try verifyGuard() } catch { return nil }
        return continuityEvidence.context(profiles: profiles, foregroundA2DP: true, at: environment.now())
    }
    private var ownedMDEConfigured = false
    private var ownedMDEExpectedConfiguration: Data?
    private var ownedMDEEchoMatches: Bool?
    private var ownedMDEEchoStatus: String?
    var peerDiagnostics: (() -> [String: Any])?
    private var peerOwnership = NativeSamsungPeerCoordinatorOwnership()
    private var lastPeerAcquisitionEpoch: UUID?
    private var ownsMac = false { didSet { updatePeerOwnership() } }
    private func updatePeerOwnership() {
        let change = peerOwnership.update(enabled: enabled, ownsMac: ownsMac, status: evidence.status)
        if change.lost { onMacOwnershipLost?() }
        if let epoch = change.acquired {
            lastPeerAcquisitionEpoch = epoch
            onMacAcquired?(epoch, address)
        }
    }
    /// Rebind both sides after an explicit account-session refresh. Rotating
    /// only the coordinator UUID would make the next valid yield receipt stale.
    @discardableResult func refreshPeerOwnershipAnnouncement() -> Bool {
        guard canManageSettings, evidence.status?.state == .foreground,
              evidence.status?.streamType.rawValue == 1,
              let target = try? environment.output(address), environment.defaultOutput() == target else { return false }
        do { try verifyGuard() } catch { return false }
        peerOwnership = NativeSamsungPeerCoordinatorOwnership()
        updatePeerOwnership()
        return true
    }
    private var controlPrepared = false {
        didSet { if !controlPrepared { continuityEvidence.reset(); playbackReport = nil; firmwareInfo = nil; ownedMDEConfigured = false; ownedMDEExpectedConfiguration = nil; ownedMDEEchoMatches = nil; ownedMDEEchoStatus = nil } }
    }
    private var controlEpoch: UInt64 = 0
    private var physicalRelease: Task<Void, Never>?
    private var releaseDeadline: Task<Void, Never>?
    private var physicalLinkAbsent = false
    private var releaseSuperseded = false
    private var coldWait = false
    private var prearmWaitingAllowed = true
    private var unknownPlaybackGuard = NativeUnknownPlaybackGuardPolicy()
    private var preserveGuardOnDeinit = false
    private var unprotectedOutput: UInt32?
    private var transitionEpoch: UInt64 = 0
    private var pauseSerial: UInt64 = 0
    // A superseded yield still owes a release on the next actual background.
    private var yieldRequired = false
    private var yieldAwaitingRemote = false
    private var yieldFinished = false
    private var yieldShouldNotify = false
    private var originalFailure: String?
    private var controllerEvents: [[String: Any]] = []
    private var requesting = false
    private var battery: BudsBatterySnapshot?
    var batterySnapshot: BudsBatterySnapshot? { battery }
    private var termination: NSObjectProtocol?

    init(environment: NativeSwitchEnvironment? = nil) {
        self.environment = environment ?? .live()
        termination = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        if let termination { NotificationCenter.default.removeObserver(termination) }
        monitor?.cancel(); audioRecovery?.cancel(); switchDeadline?.cancel(); pauseTask?.cancel(); releaseDeadline?.cancel()
        let environment = environment
        let stopPeer = onPeerLifecycle
        let preserveGuard = preserveGuardOnDeinit
        Task { @MainActor in
            stopPeer?(false)
            environment.handlers(nil, nil)
            environment.close()
            // A failed pause deliberately leaves the existing recovery journal.
            if !preserveGuard { try? await Self.restoreAfterPause(environment) }
            environment.stopPlayback()
        }
    }

    func refresh() async {
        guard !enabled, !busy else { return }
        guard !recoveryPending else {
            status = "Aguardando a restauração automática do som do Mac."; return
        }
        let token = generation
        do {
            let devices = try await environment.pairedBuds()
            guard generation == token, !enabled, !busy, !recoveryPending, !Task.isCancelled else { return }
            buds = devices
        } catch {
            guard generation == token, !enabled, !busy, !Task.isCancelled else { return }
            self.error = error.localizedDescription
            status = "Não foi possível atualizar os dispositivos Bluetooth. Tente novamente."
            return
        }
        if !buds.contains(where: { $0.address == selectedBuds }) { selectedBuds = buds.first?.address ?? "" }
        ready = !selectedBuds.isEmpty
        error = nil
        status = ready ? "Buds pareados encontrados. Ative para usar o transporte Samsung." : "Pareie os Buds nos ajustes Bluetooth do Mac."
    }

    func configurationChanged() {
        guard !enabled, !busy else { return }
        ready = false
        status = "Verifique novamente os Buds selecionados."
    }

    func start(transportGranted: Bool) {
        guard !enabled, !busy, cleanup == nil else { return }
        record("start_requested")
        guard !transportIsSettling else {
            error = "Aguarde o Bluetooth concluir a tentativa anterior antes de ativar novamente."; return
        }
        guard transportGranted else {
            error = "O cliente principal precisa ceder o controle Bluetooth exclusivo antes de ativar."
            status = "Transporte Samsung não autorizado."
            return
        }
        guard !environment.isArmed() else {
            let message = "Aguarde a restauração automática do som antes de iniciar outra sessão."
            if error?.contains(message) != true { error = [error, message].compactMap { $0 }.joined(separator: "\n") }
            status = "Aguardando a restauração automática do som do Mac."; return
        }
        guard ready, buds.contains(where: { $0.address == selectedBuds }) else {
            error = "Verifique os Buds selecionados antes de ativar."; return
        }
        generation &+= 1
        address = selectedBuds
        name = buds.first(where: { $0.address == address })?.name ?? "Galaxy Buds"
        recovery = NativeSwitchRecoveryPolicy()
        cooldownUntil = 0
        pendingLocalIntent = nil
        originalFailure = nil
        coldWait = false; prearmWaitingAllowed = true; physicalLinkAbsent = false
        unknownPlaybackGuard.reset()
        preserveGuardOnDeinit = false
        battery = environment.loadBattery(address)
        enabled = true; busy = true; error = nil
        launch(generation)
    }

    private func record(_ kind: String, _ fields: [String: Any] = [:]) {
        var event = fields; event["event"] = kind; event["uptime"] = environment.now()
        controllerEvents.append(event)
        if controllerEvents.count > 100 { controllerEvents.removeFirst(controllerEvents.count - 100) }
    }

    private func launch(_ token: UInt64, delay: TimeInterval = 0) {
        let sleep = environment.sleep
        monitor = Task { [weak self] in
            do {
                if delay > 0 { try await sleep(delay) }
                guard self?.active(token) == true else { return }
                try await self?.prepare(token)
                while !Task.isCancelled {
                    // Do not retain the model throughout this indefinite loop.
                    // Explicit close is primary; releasing the owner must still
                    // make deinit cleanup reachable between iterations.
                    guard self?.active(token) == true else { return }
                    try await self?.tick(token)
                    try await sleep(0.2)
                }
            } catch {
                guard let self, self.active(token) else { return }
                self.finish(failure: "Alternância interrompida: \(error.localizedDescription)", retry: !(error is NativeSwitchSafetyError),
                            preserveGuard: self.unknownPlaybackGuard.isObserving && error is NativeSwitchSafetyError)
            }
        }
    }

    private func active(_ token: UInt64) -> Bool { enabled && generation == token && !Task.isCancelled }
    private func check(_ token: UInt64) throws { guard active(token) else { throw CancellationError() } }

    private func prepare(_ token: UInt64) async throws {
        try check(token)
        // An accepted SDK operation cannot be cancelled by a generation flag.
        // Wait before touching mute/playback while an older operation drains.
        while (environment.diagnostics()["pending_operations"] as? Int ?? 0) > 0 {
            status = "Aguardando o Bluetooth concluir a tentativa anterior…"
            try await environment.sleep(0.25)
            try check(token)
        }
        // No evidence or playback baseline crosses a transport session boundary.
        lastPeerAcquisitionEpoch = nil
        bannerRemoteOwnership = false
        evidence = NativeSwitchEvidence(); ownsMac = false; requesting = false; controlPrepared = false
        unknownPlaybackGuard.reset()
        onPeerLifecycle?(true)
        transitionEpoch &+= 1
        yieldRequired = false
        yieldAwaitingRemote = false; yieldFinished = false; yieldShouldNotify = false
        pendingLocalIntent = nil
        route = "Sem saída confirmada"; phoneActivity = "Sem leitura"
        // Baseline before radio discovery: a play while linked() is suspended
        // belongs to this session, while playback already running does not.
        environment.startPlayback(); playbackStarted = true
        let initial = try await activity()
        try check(token)
        _ = evidence.playEdge(playing: initial.0.output, revision: initial.1.revision)
        unprotectedOutput = environment.defaultOutput()
        // Close the poll-to-play speaker leak before discovery. Playback already
        // active at enable is a baseline and must keep its existing route/sound.
        if environment.releaseBluetooth != nil, waitSilently, prearmWaitingAllowed,
           !initial.0.output, initial.1.isPlaying != true {
            try await protectWaitingOutput(token)
        }
        status = "Verificando a conexão atual dos Buds…"
        let connected = try await environment.linked(address)
        try check(token)
        if environment.isArmed() { try verifyGuard(); try permittedRoute() }
        guard environment.isArmed() || environment.defaultOutput() == unprotectedOutput else {
            throw NativeSwitchSafetyError(message: "A saída mudou durante a espera. A escolha atual será respeitada.")
        }
        let preservePlayingBaseline = environment.releaseBluetooth != nil && initial.0.output
        if connected, !coldWait, !preservePlayingBaseline {
            try await protectWaitingOutput(token)
            try await prepareControl(token)
        }
        else { record("waiting_disconnected") }
        stableSince = environment.now()
        busy = false
        status = controlPrepared ? "Espera silenciosa ativa. Inicie uma nova reprodução no Mac." :
            "Aguardando play no Mac para conectar os Buds automaticamente."
    }

    private func protectWaitingOutput(_ token: UInt64) async throws {
        if environment.isArmed() { try verifyGuard(); return }
        let target = try environment.output(address)
        guard let fallback = try environment.waitingOutput(target) else {
            throw NativeBudsError(message: "Não foi possível proteger a saída anterior do Mac.")
        }
        try await environment.arm(fallback)
        try check(token)
        try verifyGuard()
        unprotectedOutput = nil
        record("waiting_output_protected")
    }

    private func prepareControl(_ token: UInt64, forPlayback: Bool = false) async throws {
        guard physicalRelease == nil else { throw CancellationError() }
        while (environment.diagnostics()["pending_operations"] as? Int ?? 0) > 0 {
            try await environment.sleep(0.1)
            try check(token)
        }
        try verifyGuard(); try permittedRoute()
        if forPlayback, environment.releaseBluetooth != nil {
            guard try await handoffStillWanted(token) else { return }
        }
        controlEpoch &+= 1
        let epoch = controlEpoch
        if let ownBuds = try? NativeSamsungPeerCoordinator.address(address) {
            continuityEvidence.begin(address: ownBuds, at: environment.now())
        } else { continuityEvidence.reset() }
        environment.handlers({ [weak self] frame in
            guard let self, self.active(token), self.controlEpoch == epoch else { return }
            self.receive(frame, token: token)
        }, { [weak self] failure in
            guard let self, self.active(token), self.controlEpoch == epoch else { return }
            self.finish(failure: failure.message, retry: true)
        })
        status = "Conectando automaticamente aos Buds…"
        record("control_open_requested")
        physicalLinkAbsent = false
        try await environment.open(address)
        try check(token)
        // No state received before this control session can confirm its handoff.
        evidence.resetVendorState()
        var configuration = try await ownedMDEConfiguration?() ?? SamsungMdePacket.configureVersion3()
        if laboratoryMDEVersion2 { configuration = try SamsungMdePacket.version2OwnedConfiguration(from: configuration) }
        try check(token)
        try verifyGuard(); try permittedRoute()
        try environment.send(laboratoryMobileMDEProfile ? SamsungMdePacket.settingInfoMobileCompatibilityBluetooth() : SamsungMdePacket.settingInfoClassicBluetooth())
        try check(token)
        ownedMDEExpectedConfiguration = ownedMDEConfiguration == nil ? nil : configuration
        try environment.send(configuration)
        ownedMDEConfigured = ownedMDEConfiguration != nil
        try check(token)
        try environment.send(SamsungMdePacket.readCurrentStates())
        try check(token)
        try environment.send(SamsungMdePacket.readSeamlessConnection())
        try check(token)
        controlPrepared = true
        record("control_opened")
    }

    private func activity() async throws -> (AudioActivity, MacPlaybackIntent, rawOutput: Bool) {
        guard playbackStarted else { throw CancellationError() }
        var audio = try environment.activity()
        let rawOutput = audio.output
        let intent = await environment.sample()
        playbackDetection = intent.isPlaying == nil ? "Atividade de áudio (limitada)" : "Play/pause"
        if let playing = intent.isPlaying { audio.output = playing || (audio.input && audio.output) }
        macActivity = audio.output ? "Reproduzindo no Mac" : "Sem reprodução"
        return (audio, intent, rawOutput)
    }

    private func tick(_ token: UInt64) async throws {
        try check(token)
        if environment.now() - stableSince >= 30 { recovery.stable() }
        guard !controlPrepared || environment.isOpen() else { throw NativeBudsError(message: "O canal Samsung foi fechado.") }
        guard selectedBuds == address else {
            ready = false
            throw NativeSwitchSafetyError(message: "A seleção mudou durante a sessão. Verifique novamente.")
        }
        if environment.isArmed() {
            try verifyGuard()
            try permittedRoute()
        } else {
            guard !controlPrepared, !ownsMac, environment.defaultOutput() == unprotectedOutput else {
                throw NativeSwitchSafetyError(message: "A saída mudou durante a espera. A escolha atual será respeitada.")
            }
        }
        try await settlePause(token)
        let sampledEpoch = transitionEpoch
        let (audio, intent, rawOutput) = try await activity()
        try check(token)
        if transitionEpoch != sampledEpoch {
            unknownPlaybackGuard.reset()
            try await settlePause(token)
            return // A handoff superseded this activity observation.
        }
        let edge = evidence.playEdge(playing: intent.isPlaying == true, revision: intent.revision,
                                     trustworthy: intent.isPlaying != nil)
        let waitingOutput = environment.armedDevice()
        let budsOutput = try environment.output(address)
        let unknownPlaybackDue = unknownPlaybackGuard.observe(at: environment.now(), halOutput: rawOutput,
            mediaPlaying: intent.isPlaying,
            eligible: environment.releaseBluetooth != nil && environment.isArmed()
                && !requesting && !ownsMac && physicalRelease == nil && pauseTask == nil && !yieldRequired
                && !evidence.callActive && !audio.input && waitingOutput != nil
                && environment.defaultOutput() == waitingOutput
                && waitingOutput != budsOutput
                && waitingOutput.map { environment.outputBelongsToBuds?($0, address) != true } == true)
        if unknownPlaybackDue {
            try await releaseUnknownPlaybackGuard(token)
            return
        }
        if physicalRelease != nil, edge || audio.input || evidence.callActive {
            releaseSuperseded = true
        }
        // HAL activity and input/output streams may veto restoration or express
        // a busy call, but cannot create media acquisition intent. In particular,
        // an expired reading must not release a previously latched request.
        if intent.isPlaying != true || evidence.callActive || (environment.releaseBluetooth != nil && audio.input) { pendingLocalIntent = nil }
        else if edge, !ownsMac {
            onLocalPlaybackIntent?()
            pendingLocalIntent = intent.revision
            record("local_playback_edge_accepted", [
                "revision": intent.revision,
                "observed_at": intent.observedAt.map { $0 as Any } ?? NSNull()
            ])
        }
        // An accepted OS close cannot be revoked. Continue sampling intent and
        // respecting manual routes while it drains, without overlapping opens.
        if physicalRelease != nil { try verifyReleaseRoute(); return }
        if environment.releaseBluetooth != nil, !ownsMac, !audio.output, intent.isPlaying == false,
           waitSilently, prearmWaitingAllowed, !environment.isArmed() {
            try await protectWaitingOutput(token)
        }
        if evidence.callActive {
            if audio.output { queueYield(token, notify: false); try await settlePause(token) }
            status = "Chamada tem prioridade. Aguardando uma nova reprodução após a chamada."
        } else if !ownsMac, pendingLocalIntent != nil, environment.now() >= cooldownUntil {
            pendingLocalIntent = nil
            try await takeMac(token)
        }
        try check(token)
        if ownsMac {
            guard evidence.fresh(at: environment.now()), evidence.status?.state == .foreground,
                  let target = try environment.output(address), environment.defaultOutput() == target else {
                throw NativeBudsError(message: "A saída dos Buds perdeu a confirmação atual.")
            }
            if !audio.input, let playing = intent.isPlaying {
                try reportPlayback(playing ? .playing : .paused)
            }
            // An established, open RFCOMM channel plus the live HAL endpoint
            // and vendor session is the health proof. Re-running system_profiler
            // here stalls the audio loop and one slow diagnostic can terminate
            // otherwise healthy playback. Its fresh ACL check remains mandatory
            // for every acquisition; channel-close/HAL loss ends ownership here.
        }
    }

    private func releaseUnknownPlaybackGuard(_ token: UInt64) async throws {
        // No pause command: MediaRemote may describe an unrelated, paused app.
        // No route write: only the already-selected, owned waiting output is eligible.
        do {
            // The MediaRemote sample suspended after the first HAL read. Input
            // or a disappearing output during that await must veto restoration.
            let currentAudio = try environment.activity()
            guard currentAudio.output, !currentAudio.input, !evidence.callActive else {
                unknownPlaybackGuard.reset()
                return
            }
            try verifyReleaseRoute()
            prearmWaitingAllowed = false
            controlEpoch &+= 1
            environment.handlers(nil, nil)
            controlPrepared = false
            environment.close()
            let previousOutput = environment.defaultOutput()
            try await environment.restore()
            try check(token)
            guard !environment.isArmed(), environment.defaultOutput() == previousOutput else {
                throw NativeSwitchSafetyError(message: "A restauração da saída anterior não foi confirmada.")
            }
            unprotectedOutput = previousOutput
            unknownPlaybackGuard.reset()
            status = "O app de reprodução não informou o status. Som liberado na saída anterior."
            record("unreported_playback_guard_released")
        } catch {
            // Do not fall through to pause/restore cleanup or clear a journal
            // whose ownership/verification failed. Automatic silent recovery remains available.
            throw NativeSwitchSafetyError(message: error.localizedDescription)
        }
    }

    private func takeMac(_ token: UInt64) async throws {
        // Known calls veto before any request; absence of vendor state does not.
        guard !evidence.callActive else { return }
        onLocalPlaybackIntent?()
        // One end-to-end budget covers discovery/opening too. A headset out of
        // range must not consume a fresh full timeout at every transport stage.
        let deadline = environment.now() + NativeSwitchRecoveryPolicy.handoffTimeout
        acquisitionDeadline = deadline
        requesting = true; busy = true
        switchDeadline = Task { [weak self] in
            do { try await self?.environment.sleep(NativeSwitchRecoveryPolicy.handoffTimeout) } catch { return }
            guard let self, self.active(token), self.requesting else { return }
            self.finish(failure: "Os Buds não ficaram disponíveis em doze segundos. Reprodução pausada; o som do Mac será restaurado.", retry: true)
        }
        defer {
            if generation == token {
                requesting = false; switchDeadline?.cancel(); switchDeadline = nil
                acquisitionDeadline = nil
                if enabled { busy = false }
            }
        }
        try await protectWaitingOutput(token)
        if !controlPrepared {
            try await prepareControl(token, forPlayback: true)
            try check(token)
            guard controlPrepared else { return }
            let wanted = try await handoffStillWanted(token)
            guard wanted else { return }
        }
        if environment.releaseBluetooth != nil {
            // Re-sample user intent after the new control bootstrap. READ replies
            // are not correlated ownership evidence, and the firmware need not
            // send an unsolicited NOTIFY before a request. Keep write-first,
            // then require this session's post-request ownership confirmation.
            guard try await handoffStillWanted(token) else { return }
            record("control_bootstrap_intent_confirmed")
        }
        // Starting another request does not discharge an aborted release if
        // the Buds are still selected. A user pause may abort this request too.
        if environment.defaultOutput() == environment.armedDevice() { yieldRequired = false }
        yieldAwaitingRemote = false; yieldFinished = false
        if !yieldRequired { yieldShouldNotify = false }
        // At enable/reconnect, the Buds may already be the actual Mac output.
        // Windows retains foreground state; an identical notification need not
        // arrive again. Adopt only with an existing HAL route and fresh radio
        // confirmation, both still valid after awaiting the radio read.
        if evidence.status?.state == .foreground,
           let target = try environment.output(address), environment.defaultOutput() == target {
            let serial = evidence.serial
            let linked = try await environment.linked(address)
            try check(token)
            guard try await handoffStillWanted(token) else { return }
            if linked, environment.isOpen(), evidence.serial == serial,
               evidence.status?.state == .foreground, !evidence.callActive,
               environment.defaultOutput() == target {
                try verifyGuard()
                ownsMac = true; route = "Mac"
                yieldRequired = false; yieldShouldNotify = false
                status = "Buds confirmados no Mac. A saída anterior continua protegida."
                show(galaxy: false)
                return
            }
        }
        guard !evidence.callActive else { try await pauseMac(token); return }
        status = "Solicitando os Buds para o Mac…"
        let requestedAfter = evidence.serial
        let requestedNotification = evidence.notificationCount
        // Windows writes first, then waits. No pre-request state read or output
        // announcement can be mistaken for ownership or request acceptance.
        let request = laboratoryAndroidMetadataRequest ? SamsungMdePacket.requestAndroidMetadataSwitch()
            : laboratoryMobileMDEProfile ? SamsungMdePacket.requestMobileCompatibilitySwitch()
            : SamsungMdePacket.requestComputerSwitch()
        try environment.send(request)
        record("mac_request_sent")
        try check(token)
        while active(token) {
            guard environment.now() < deadline else {
                throw NativeBudsError(message: "A troca não foi confirmada em doze segundos.")
            }
            try await settlePause(token)
            if evidence.callActive { return }
            let intent = await environment.sample()
            try check(token)
            if intent.isPlaying == false, intent.reportedIsPlaying != true {
                status = "Reprodução pausada. Aguardando uma nova reprodução no Mac."
                return
            }
            if evidence.serial > requestedAfter, evidence.backgroundStreamRejected {
                throw NativeBudsError(message: "Os Buds recusaram a reprodução em segundo plano (132).")
            }
            if evidence.confirmsMac(after: requestedAfter, afterNotification: requestedNotification, at: environment.now()) {
                let serial = evidence.serial
                let linked = try await environment.linked(address)
                let linkedAt = environment.now()
                try check(token)
                guard try await handoffStillWanted(token) else { return }
                if linked, environment.now() < deadline,
                   evidence.confirmsMac(after: requestedAfter, afterNotification: requestedNotification, at: environment.now()),
                   evidence.serial == serial, let target = try environment.output(address) {
                    try await environment.setOutput(target)
                    try check(token)
                    guard try await handoffStillWanted(token) else { return }
                    guard environment.now() < deadline,
                          evidence.confirmsMac(after: requestedAfter, afterNotification: requestedNotification, at: environment.now()),
                          evidence.serial == serial, environment.now() - linkedAt <= 2,
                          environment.defaultOutput() == target else { continue }
                    try verifyGuard()
                    ownsMac = true; route = "Mac"
                    yieldRequired = false; yieldShouldNotify = false
                    status = "Buds confirmados no Mac. A saída anterior continua protegida."
                    show(galaxy: false, acquiredFromRemote: bannerRemoteOwnership)
                    return
                }
            }
            try await environment.sleep(0.15)
        }
        throw CancellationError()
    }

    private func receive(_ frame: SamsungMdePacket.Frame, token: UInt64) {
        if let version = SamsungMdePacket.firmwareVersion(frame) {
            firmwareInfo = (address: address, version: version, date: Date())
        }
        if let session = continuityEvidence.session {
            continuityEvidence.observe(frame, session: session, at: environment.now())
        }
        if let configured = ownedMDEExpectedConfiguration,
           let status = SamsungMdePacket.accountTagEchoStatus(frame, ownedConfiguration: configured) {
            ownedMDEEchoMatches = status == .matching
            ownedMDEEchoStatus = status.rawValue
        }
        let values = SamsungMdePacket.batteryProperties(frame)
        if !values.isEmpty {
            battery = BudsBatterySnapshot(address: address, name: name, model: battery?.model ?? "",
                // A partial notification dates only the fields it contains.
                // Carrying an old case/right value into this new timestamp
                // would falsely keep that percentage fresh indefinitely.
                icon: battery?.icon, left: values[0x0208],
                right: values[0x0209], casePercent: values[0x020A],
                observedAt: Date().timeIntervalSince1970)
        }
        // READ_PROPERTY has no proven request correlation and may already be
        // stale when it arrives. It must never overwrite a newer background or
        // call notification, even before the first play. Use only vendor NOTIFY
        // for ownership evidence; READ responses remain useful for battery above.
        guard frame.command == 0x45 else { return }
        guard let value = SamsungMdePacket.multipointStatus(frame) else { return }
        let wasMac = ownsMac
        defer { updatePeerOwnership() }
        let changed = evidence.observe(value, at: environment.now())
        // A repeated vendor notification is new ingress, even when its state
        // equals the previous notification. Admit at most once per acquisition,
        // never during our own request, calls, recovery or another yield.
        if laboratoryCooperativeForegroundRejection, wasMac, !requesting, !busy,
           controlPrepared, environment.isOpen(), pauseTask == nil, !yieldRequired,
           physicalRelease == nil, value.state == .foreground, value.reason == 132,
           value.streamType.rawValue == 1, macActivity == "Reproduzindo no Mac",
           let epoch = lastPeerAcquisitionEpoch, cooperativePauseEpoch != epoch,
           (try? environment.activity().input) == false,
           let target = try? environment.output(address), environment.defaultOutput() == target {
            do {
                try verifyGuard(); try permittedRoute()
                cooperativePauseEpoch = epoch
                record("cooperative_pause_requested")
                queueYield(token, notify: true, provisional: true)
            } catch { /* A radio hint cannot override a changed route/guard. */ }
        }
        guard changed else { return }
        // Only actual vendor NOTIFY with a known remote stream is ownership
        // proof. An empty stream is not evidence that ownership changed. Keep
        // the preceding fact across pause/bootstrap until acquisition consumes
        // it, independently of the controller's vendor-state resets.
        if !value.rejectsBackgroundStream, evidence.remoteStream { bannerRemoteOwnership = true }
        transitionEpoch &+= 1
        record("vendor_state", ["state": Int(value.state.rawValue), "stream": Int(value.streamType.rawValue), "reason": Int(value.reason)])
        phoneActivity = value.isCall ? "Chamada em andamento" : evidence.remoteStream ? "Reprodução remota confirmada" : "Sem stream remoto confirmado"
        if evidence.backgroundStreamRejected, requesting || wasMac {
            finish(failure: "Os Buds recusaram a reprodução em segundo plano (132).", retry: true)
            return
        }
        if value.state == .background || value.isCall {
            ownsMac = false; route = "Sem saída confirmada"
            // Startup/background snapshots are not ownership loss. Pause for a
            // confirmed loss, a call, or a previously aborted release obligation.
            if wasMac || value.isCall || yieldRequired {
                pendingLocalIntent = nil
                cooldownUntil = environment.now() + NativeSwitchRecoveryPolicy.audioLossCooldown
                queueYield(token, notify: wasMac)
            }
            confirmGalaxyIfReady()
            status = value.isCall ? "Chamada tem prioridade." : "Samsung em segundo plano. Aguardando nova reprodução no Mac."
        }
    }

    /// Called only for READY correlated by the authenticated selected-phone
    /// coordinator. Intent authorizes a guarded local yield, not remote ownership.
    func requestYieldForAuthenticatedReady(epoch: UUID, budsAddress: String) {
        guard epoch == lastPeerAcquisitionEpoch,
              BudsBatterySnapshot.normalize(budsAddress) == BudsBatterySnapshot.normalize(address) else { return }
        record("account_ready_intent_observed")
        requestCooperativeYield(event: "account_ready_yield_requested", releaseForegroundRoute: true)
    }

    private func requestCooperativeYield(event: String, releaseForegroundRoute: Bool) {
        guard enabled, ownsMac, !requesting, !busy, !draining, cleanup == nil,
              controlPrepared, environment.isOpen(), pauseTask == nil, !yieldRequired,
              physicalRelease == nil, evidence.status?.state == .foreground,
              !evidence.callActive, evidence.status?.streamType.rawValue == 1,
              let epoch = lastPeerAcquisitionEpoch, cooperativePauseEpoch != epoch,
              (try? environment.activity().input) == false,
              let target = try? environment.output(address), environment.defaultOutput() == target else { return }
        do {
            try verifyGuard(); try permittedRoute()
            cooperativePauseEpoch = epoch
            record(event)
            queueYield(generation, notify: true, provisional: true, releaseForegroundRoute: releaseForegroundRoute)
        } catch { /* No route effect when the owned guard cannot be verified. */ }
    }

    #if DEBUG
    /// Timing lab only; no Release entry point or peer-evidence fabrication.
    func laboratoryYieldForObservedPhoneIntent() {
        guard laboratoryCooperativeForegroundRejection, laboratoryProvisionalRouteRelease else { return }
        requestCooperativeYield(event: "laboratory_phone_intent_yield_requested", releaseForegroundRoute: true)
    }
    #endif

    private func queueYield(_ token: UInt64, notify: Bool, provisional: Bool = false,
                            releaseForegroundRoute: Bool = false) {
        yieldRequired = true
        yieldAwaitingRemote = true
        yieldShouldNotify = yieldShouldNotify || notify
        guard pauseTask == nil else { return }
        yieldFinished = false
        pauseSerial &+= 1
        let serial = pauseSerial
        let acquisitionEpoch = lastPeerAcquisitionEpoch
        pauseTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.pauseSerial == serial { self.pauseTask = nil } }
            guard self.active(token) else { return }
            do {
                if provisional, self.evidence.status?.state == .foreground {
                    let intent = await self.environment.sample()
                    try self.check(token)
                    let input = try self.environment.activity().input
                    if self.evidence.status?.state == .foreground,
                       intent.isPlaying != true || input {
                        self.yieldRequired = false; self.yieldAwaitingRemote = false
                        self.yieldShouldNotify = false
                        self.record("cooperative_pause_vetoed")
                        return
                    }
                }
                let result = try await self.yieldMac(token,
                    allowForegroundRouteRelease: provisional && (releaseForegroundRoute || self.laboratoryProvisionalRouteRelease))
                guard self.active(token) else { return }
                switch result {
                case .completed:
                    self.yieldRequired = false
                    self.yieldFinished = true
                    if let acquisitionEpoch { self.onMacYieldPrepared?(acquisitionEpoch, self.address) }
                    self.confirmGalaxyIfReady()
                case .aborted:
                    self.yieldAwaitingRemote = false
                    self.yieldFinished = false
                    // Foreground132 does not owe or authorize a route release.
                    // If it never becomes a real ownership loss, keep the Mac
                    // selected and permit settings/a later explicit user play.
                    if provisional, self.ownsMac, self.evidence.status?.state == .foreground {
                        self.yieldRequired = false
                        self.yieldShouldNotify = false
                    }
                    // Keep the release obligation and its notification intent,
                    // but never let a later media frame confirm this abort.
                    self.record("mac_yield_aborted")
                }
            } catch {
                if self.active(token) {
                    if provisional, self.ownsMac, self.evidence.status?.state == .foreground,
                       !self.evidence.callActive, !(error is NativeSwitchSafetyError) {
                        self.yieldRequired = false; self.yieldAwaitingRemote = false
                        self.yieldFinished = false; self.yieldShouldNotify = false
                        self.record("cooperative_pause_unconfirmed")
                        return
                    }
                    self.finish(failure: "Não foi possível liberar a saída do Mac: \(error.localizedDescription)",
                                retry: !(error is NativeSwitchSafetyError))
                }
                throw error
            }
        }
    }

    private func confirmGalaxyIfReady() {
        guard yieldAwaitingRemote, yieldFinished, !yieldRequired, evidence.remoteStream else { return }
        if environment.releaseBluetooth != nil {
            guard !evidence.callActive, physicalRelease == nil else { return }
            beginPhysicalRelease()
            return
        }
        route = "Galaxy"
        if yieldShouldNotify { show(galaxy: true) }
        yieldAwaitingRemote = false; yieldShouldNotify = false
        record("galaxy_yield_confirmed")
    }

    private func beginPhysicalRelease() {
        guard let release = environment.releaseBluetooth, physicalRelease == nil else { return }
        let token = generation
        releaseSuperseded = false
        busy = true
        physicalRelease = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token {
                    self.releaseDeadline?.cancel(); self.releaseDeadline = nil
                    self.physicalRelease = nil
                    self.busy = false
                }
            }
            do {
                // The pause baseline is recorded by pauseMac immediately, before
                // awaiting the HAL route. A later play must remain a new edge.
                let intent = await self.environment.sample()
                try self.check(token)
                try self.verifyReleaseRoute()
                guard intent.isPlaying == false, self.evidence.remoteStream, !self.evidence.callActive,
                      try !self.environment.activity().input,
                      self.environment.defaultOutput() == self.environment.armedDevice() else {
                    // A call can postpone release until a later media NOTIFY.
                    // A new local play instead supersedes this remote yield.
                    if intent.isPlaying != false || !self.evidence.callActive {
                        self.yieldAwaitingRemote = false
                    }
                    self.record("physical_release_aborted")
                    return
                }
                // Samsung's Android profile migration schedules its final
                // device.connect after two seconds (MCFDS cc.k.d). A remote
                // media NOTIFY can precede the phone's AudioDevice callback.
                // Keep the guarded background channel briefly while that
                // native route settles; new local play/call/manual route vetoes
                // this release before any non-cancellable ACL close is issued.
                self.record("physical_release_settling_started")
                let delay = self.environment.remoteReleaseSettleDelay
                guard delay.isFinite, (0...2).contains(delay) else {
                    throw NativeSwitchSafetyError(message: "Prazo de estabilização inválido.")
                }
                let settleUntil = self.environment.now() + delay
                while self.environment.now() < settleUntil {
                    try await self.environment.sleep(0.1)
                    try self.check(token)
                    try self.verifyReleaseRoute()
                    let current = await self.environment.sample()
                    try self.check(token)
                    try self.verifyReleaseRoute()
                    guard !self.releaseSuperseded, current.isPlaying == false,
                          self.evidence.remoteStream, !self.evidence.callActive,
                          try !self.environment.activity().input else {
                        self.yieldAwaitingRemote = false
                        self.record("physical_release_settling_aborted")
                        return
                    }
                }
                try self.verifyReleaseRoute()
                self.record("physical_release_prerequisites_confirmed")
                let deadline = self.environment.now() + NativeSwitchRecoveryPolicy.handoffTimeout
                self.releaseDeadline = Task { [weak self] in
                    guard let self else { return }
                    do { try await self.environment.sleep(NativeSwitchRecoveryPolicy.handoffTimeout) }
                    catch { return }
                    guard self.active(token), self.physicalRelease != nil else { return }
                    self.record("physical_release_timeout")
                    self.finish(failure: "A desconexão física do Mac não foi confirmada em doze segundos.", retry: true)
                }
                // An intentional RFCOMM close is not a transport failure. Fence
                // even retained callbacks within this same enabled generation.
                self.controlEpoch &+= 1
                self.environment.handlers(nil, nil)
                self.controlPrepared = false; self.ownsMac = false
                self.coldWait = true
                self.environment.close()
                self.evidence.resetVendorState()
                self.record("control_closed_for_physical_release")
                self.status = "Liberando a conexão Bluetooth do Mac…"
                self.record("physical_close_requested")
                // This SDK effect may ignore cancellation. Keep its task lease
                // through Stop/timeout; cleanup cannot launch another open yet.
                try await release(self.address)
                try self.check(token)
                self.record("physical_close_returned")
                while true {
                    try self.verifyReleaseRoute()
                    let linked = try await self.environment.linked(self.address)
                    try self.check(token)
                    try self.verifyReleaseRoute()
                    guard self.environment.now() < deadline else {
                        throw NativeBudsError(message: "A desconexão física do Mac excedeu o prazo de doze segundos.")
                    }
                    if !linked { break }
                    try await self.environment.sleep(0.25)
                    try self.check(token)
                }
                // Never infer ACL absence from closeConnection's return value.
                self.physicalLinkAbsent = true
                self.record("physical_link_absent_observed")
                self.controlPrepared = false; self.ownsMac = false
                self.evidence.resetVendorState()
                self.unprotectedOutput = nil // the waiting guard remains owned
                let after = await self.environment.sample()
                try self.check(token)
                try self.verifyReleaseRoute()
                let input = try self.environment.activity().input
                let superseded = self.releaseSuperseded || after.isPlaying != false || input
                self.route = superseded ? "Sem saída confirmada" : "Galaxy"
                if !superseded, self.yieldShouldNotify { self.show(galaxy: true) }
                self.yieldAwaitingRemote = false; self.yieldShouldNotify = false
                self.status = "Mac desconectado dos Buds. Aguardando nova reprodução no Mac."
                if superseded { self.record("physical_release_result_superseded") }
                self.record("waiting_disconnected_after_release")
            } catch {
                guard self.active(token) else { return }
                self.record("physical_release_failed")
                self.finish(failure: "Não foi possível confirmar a liberação Bluetooth do Mac: \(error.localizedDescription)",
                            retry: !(error is NativeSwitchSafetyError))
            }
        }
    }

    private func settlePause(_ token: UInt64) async throws {
        while let task = pauseTask {
            let serial = pauseSerial
            try await task.value
            try check(token)
            if pauseSerial == serial { pauseTask = nil }
        }
    }

    private func pauseMac(_ token: UInt64) async throws {
        guard playbackStarted else { return }
        try await environment.pause()
        try check(token)
        let after = await environment.sample()
        try check(token)
        guard try paused(after), environment.releaseBluetooth == nil || after.isPlaying == false else {
            throw NativeBudsError(message: "A pausa do reprodutor do Mac não foi confirmada.")
        }
        record("mac_pause_confirmed")
        // This is a factual report, not a switch request or media command. The
        // Windows packet builder and observed Android writes share opcode0x0C.
        // Never send PAUSED before the real local player pause is verified.
        try reportPlayback(.paused)
        // Consume our own pause as the new baseline, enabling a later real play.
        _ = evidence.playEdge(playing: false, revision: after.revision)
        pendingLocalIntent = nil
    }

    private func reportPlayback(_ status: SamsungMdePacket.PlaybackStatus) throws {
        guard laboratoryPlaybackReports, controlPrepared, environment.isOpen(), playbackReport != status else { return }
        try environment.send(SamsungMdePacket.playbackStatus(status))
        playbackReport = status
        record("playback_report_queued", ["playing": status == .playing])
    }

    private enum YieldResult { case completed, aborted }

    /// Windows changes to system audio when a remote stream takes ownership.
    /// Closing SMEP or pausing one player does not release the Buds output route.
    /// Keep the waiting output muted so another local app cannot leak audio.
    private func yieldMac(_ token: UInt64, allowForegroundRouteRelease: Bool = false) async throws -> YieldResult {
        try verifyGuard()
        try permittedRoute()
        try await pauseMac(token)
        try check(token)
        try verifyGuard()
        try permittedRoute()
        // Authenticated READY may release the guarded HAL route early to stop
        // a retained A2DP stream. This is not remote ownership evidence.
        // A call may have started while the verified media pause suspended.
        if evidence.status?.state == .foreground, !evidence.callActive,
           allowForegroundRouteRelease, try environment.activity().input {
            record("cooperative_yield_vetoed_by_input")
            return .aborted
        }
        // Peer success, destination HUD and ACL close still require actual
        // vendor background/call evidence after the route is released.
        guard evidence.status?.state == .background || evidence.callActive || allowForegroundRouteRelease else { return .aborted }
        guard let waiting = environment.armedDevice() else {
            throw NativeSwitchSafetyError(message: "A saída de espera perdeu a proteção durante a liberação.")
        }
        if environment.defaultOutput() != waiting {
            try await environment.setOutput(waiting)
            try check(token)
        }
        try verifyGuard()
        guard environment.defaultOutput() == waiting else {
            throw NativeSwitchSafetyError(message: "A saída mudou durante a liberação dos Buds.")
        }
        // Route selection can suspend after pause was confirmed. A new play
        // during that await must not authorize a peer success response.
        if environment.releaseBluetooth != nil {
            let current = await environment.sample()
            try check(token)
            try verifyGuard()
            guard environment.defaultOutput() == waiting else {
                throw NativeSwitchSafetyError(message: "A saída mudou antes da confirmação da pausa.")
            }
            guard current.isPlaying == false else { return .aborted }
        }
        guard evidence.status?.state == .background || evidence.callActive else {
            // The submitted HAL write cannot be revoked. Reconcile to the
            // protected waiting route, with no claimed ownership or HUD. Never
            // undo it just for foreground: our pause (or a user pause) may still
            // be current. A genuine later play goes through takeMac's checks.
            ownsMac = false; route = "Sem saída confirmada"
            status = "Saída de espera protegida. Aguardando nova reprodução no Mac."
            record("yield_route_reconciled")
            return .aborted
        }
        record("waiting_route_confirmed")
        return .completed
    }

    /// Awaiting a radio/HAL read must not override a subsequent pause, Stop,
    /// manual output choice or unmute. Recheck after every asynchronous boundary.
    private func handoffStillWanted(_ token: UInt64) async throws -> Bool {
        var recordedOutputWait = false
        while true {
            try check(token)
            try verifyGuard()
            try permittedRoute()
            let intent = await environment.sample()
            try check(token)
            if evidence.callActive { try await settlePause(token); return false }
            try verifyGuard()
            try permittedRoute()
            if environment.releaseBluetooth != nil, try environment.activity().input {
                pendingLocalIntent = nil
                status = "Entrada de áudio ativa. Aguardando uma nova reprodução após a chamada."
                record("handoff_vetoed_by_input")
                return false
            }
            // The accepted edge already proved local output. While reconnecting,
            // CoreAudio briefly stops that client's IO as the Buds endpoint is
            // initialized. Wait for positive local proof again before any next
            // effect, within the SAME end-to-end budget. A raw player pause or
            // unknown player still vetoes immediately; remote-only playback cannot
            // create this transaction in tick().
            if intent.isPlaying != true, intent.reportedIsPlaying == true,
               requesting, let deadline = acquisitionDeadline {
                guard environment.now() < deadline else {
                    throw NativeBudsError(message: "A saída de áudio local não ficou pronta durante a conexão.")
                }
                if !recordedOutputWait {
                    record("handoff_waiting_for_local_output")
                    recordedOutputWait = true
                }
                try await environment.sleep(min(0.05, deadline - environment.now()))
                continue
            }
            let playing = intent.isPlaying == true
            if !playing {
                pendingLocalIntent = nil
                status = "Reprodução pausada. Aguardando uma nova reprodução no Mac."
            }
            return playing
        }
    }

    private func permittedRoute() throws {
        let current = environment.defaultOutput(), target = try environment.output(address)
        if current == environment.armedDevice() || (target != nil && current == target) { return }
        // Actual cold trace: the OS selected the Buds UID 46 ms before HAL
        // exposed output streams. It is our pending endpoint, not a user route.
        // Readiness/ownership still require output(address), fresh radio and MDE.
        if requesting, let current, environment.outputBelongsToBuds?(current, address) == true {
            record("selected_buds_endpoint_initializing")
            return
        }
        throw NativeSwitchSafetyError(message: "A saída foi alterada durante a troca. Alternância interrompida.")
    }

    private func verifyReleaseRoute() throws {
        try verifyGuard()
        guard environment.isArmed(), environment.defaultOutput() == environment.armedDevice() else {
            throw NativeSwitchSafetyError(message: "A saída mudou durante a liberação Bluetooth. A escolha atual será respeitada.")
        }
    }

    private func verifyGuard() throws {
        do { try environment.verify() }
        catch { throw NativeSwitchSafetyError(message: error.localizedDescription) }
    }

    private func paused(_ intent: MacPlaybackIntent) throws -> Bool {
        if let playing = intent.isPlaying { return !playing }
        return try !environment.activity().output
    }

    /// Silence is independent of MediaRemote acknowledgement. Never send a
    /// command to an unknown/remote client just to discharge an owned mute.
    private static func restoreAfterPause(_ environment: NativeSwitchEnvironment,
                                          allowPause: Bool = true,
                                          valid: () -> Bool = { true }) async throws {
        guard valid() else { throw CancellationError() }
        if environment.isArmed() {
            let route = environment.defaultOutput()
            let before = try environment.activity()
            var intent = await environment.sample()
            guard valid() else { throw CancellationError() }
            var audio = try environment.activity()
            guard environment.defaultOutput() == route else {
                throw NativeSwitchSafetyError(message: "A saída mudou durante a recuperação. A escolha atual será respeitada.")
            }
            if allowPause, !before.input, !audio.input,
               intent.isPlaying == true, intent.clientID != nil {
                try await environment.pause()
                guard valid() else { throw CancellationError() }
                intent = await environment.sample()
                guard valid() else { throw CancellationError() }
                audio = try environment.activity()
            }
            guard !audio.output, !audio.input, intent.isPlaying != true,
                  environment.defaultOutput() == route else {
                throw NativeBudsError(message: "Pausa não confirmada. Aguardando silêncio no Mac para restaurar automaticamente.")
            }
        }
        guard valid() else { throw CancellationError() }
        // SpeakerGuard alone arbitrates journal ownership and manual unmute.
        try await environment.restore()
    }

    private func scheduleAudioRecovery(_ token: UInt64) {
        let sleep = environment.sleep
        audioRecovery = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(1) } catch { return }
                guard self?.generation == token else { return }
                if await self?.retryAudioRecovery(token) != false { return }
            }
        }
    }

    private func retryAudioRecovery(_ token: UInt64) async -> Bool {
        guard generation == token else { return true }
        do {
            try await Self.restoreAfterPause(environment, allowPause: false,
                valid: { [weak self] in self?.generation == token && !Task.isCancelled })
            guard generation == token else { return true }
            audioRecovery = nil
            preserveGuardOnDeinit = false
            environment.stopPlayback(); playbackStarted = false
            record("audio_restored_automatically")
            if enabled, selectedBuds == address {
                status = "Som restaurado. Aguardando uma nova reprodução no Mac."
                launch(token, delay: recovery.nextDelay())
            } else {
                busy = false
                status = "Alternância desativada. Mute anterior restaurado."
            }
            return true
        } catch {
            return false
        }
    }

    private func show(galaxy: Bool, acquiredFromRemote: Bool = false) {
        if !galaxy { bannerRemoteOwnership = false }
        if let banner = environment.banner {
            guard enabled, !draining, selectedBuds == address else { return }
            // Adopting an existing Mac route and ordinary local play are silent.
            // Direct ACL connects belong exclusively to the passive monitor.
            guard galaxy || (acquiredFromRemote && ownsMac) else { return }
            banner(.init(address: address, name: name,
                kind: galaxy ? .departedFromMac(destination: nil) : .acquiredFromOtherDevice,
                occurredAt: environment.now()), battery)
            return
        }
        environment.show(name, galaxy ? "Conectado ao Galaxy" : "Conectado ao Mac", battery, address)
    }

    func stop() { finish(failure: nil) }

    private func finish(failure: String?, retry: Bool = false, preserveGuard: Bool = false) {
        if preserveGuard { preserveGuardOnDeinit = true }
        else if failure == nil && !retry { preserveGuardOnDeinit = false }
        onPeerLifecycle?(false)
        record(retry ? "recovery_requested" : "stop_requested", failure.map { ["failure": $0] } ?? [:])
        if let failure, originalFailure == nil { originalFailure = failure }
        if retry, environment.releaseBluetooth != nil {
            coldWait = true
            prearmWaitingAllowed = false // a failed/absent headset cannot freeze idle audio
        }
        // Stop also invalidates a recovery already awaiting pause/restore. That
        // cleanup must finish, but can no longer schedule a reconnect.
        if !retry { enabled = false }
        if cleanup != nil {
            if !retry { generation &+= 1 }
            return
        }
        guard enabled || environment.isArmed() || environment.isOpen() || monitor != nil else { return }
        let recovering = audioRecovery; audioRecovery = nil; recovering?.cancel()
        busy = true
        generation &+= 1
        let token = generation
        let allowRecoveryPause = !evidence.callActive
        bannerRemoteOwnership = false
        ownsMac = false; requesting = false
        controlPrepared = false
        transitionEpoch &+= 1
        yieldRequired = false
        yieldAwaitingRemote = false; yieldFinished = false; yieldShouldNotify = false
        pendingLocalIntent = nil
        unknownPlaybackGuard.reset()
        evidence = NativeSwitchEvidence()
        route = "Sem saída confirmada"; phoneActivity = "Sem leitura"
        if let failure { error = failure }
        status = "Encerrando o controle Samsung e restaurando o som…"
        switchDeadline?.cancel(); switchDeadline = nil
        let running = monitor; monitor = nil; running?.cancel()
        let pausing = pauseTask; pauseTask = nil
        let releasing = physicalRelease
        releaseDeadline?.cancel(); releaseDeadline = nil
        controlEpoch &+= 1
        environment.handlers(nil, nil)
        environment.close()
        // Cancellation fences controller continuations, but an accepted SDK/HAL
        // operation may ignore it. Restore audio now; keep the cleanup lease
        // until both tasks return so no new session can race their late effects.
        pausing?.cancel()
        releasing?.cancel()
        draining = true
        cleanup = Task { [self] in
            var restored = false
            @MainActor func restorationFailed(_ failure: Error) {
                self.error = [self.error, "Restauração pendente: \(failure.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
                status = "Aguardando silêncio no Mac para restaurar o som automaticamente."
            }
            // A passive recovery may itself be awaiting an accepted restore.
            // Fence it before another restoration attempt or a new session.
            await recovering?.value
            do {
                if preserveGuard {
                    throw NativeSwitchSafetyError(message: "Proteção mantida até ser seguro restaurar automaticamente.")
                }
                try await Self.restoreAfterPause(environment, allowPause: allowRecoveryPause,
                    valid: { [weak self] in self?.generation == token && self?.selectedBuds == self?.address })
                restored = true
                status = "Som restaurado. Aguardando a tentativa anterior terminar…"
                record("audio_restored_before_drain")
            } catch { restorationFailed(error) }

            await running?.value
            let pauseResult = await pausing?.result
            await releasing?.value
            physicalRelease = nil
            // A noncooperative open may have returned a channel after close().
            // Close it while this generation still holds the drain lease.
            environment.close()
            if case .failure(let pauseError) = pauseResult, !(pauseError is CancellationError) {
                self.error = [self.error, "Pausa anterior: \(pauseError.localizedDescription)"].compactMap { $0 }.joined(separator: "\n")
            }
            // A previously accepted arm may also finish late. Never leave its
            // journal/mute behind or start another session on top of it.
            if restored, environment.isArmed() {
                do { try await Self.restoreAfterPause(environment, allowPause: false) }
                catch { restored = false; restorationFailed(error) }
            }
            draining = false
            record("controller_work_drained")
            if restored {
                environment.stopPlayback(); playbackStarted = false
                if enabled, generation == token, selectedBuds == address {
                    let delay = recovery.nextDelay()
                    status = "Som restaurado. Reconectando o canal Samsung em \(Int(delay)) s…"
                    cleanup = nil
                    launch(token, delay: delay)
                    return
                }
                status = "Alternância desativada. Mute anterior restaurado."
            }
            busy = false; cleanup = nil
            if !restored, environment.isArmed() { scheduleAudioRecovery(generation) }
        }
    }
}
