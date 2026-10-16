import Foundation
#if canImport(Sparkle)
import Sparkle
#endif

enum NativeAppUpdateAction: Equatable {
    case check, automatic(Bool), downloads(Bool)

    /// Both settings actions use an `enabled` boolean, not a toggle or a coerced number.
    static func parse(_ request: [String: Any]) -> Self? {
        switch request["action"] as? String {
        case "app.update_check": return .check
        case "app.update_automatic":
            return NativeAppUpdateConfiguration.strictBoolean(request["enabled"]).map(Self.automatic)
        case "app.update_downloads":
            return NativeAppUpdateConfiguration.strictBoolean(request["enabled"]).map(Self.downloads)
        default: return nil
        }
    }
}

/// The pure decision is shared by relaunch, automatic installation, and ordinary quit.
enum NativeAppUpdateSafetyPolicy {
    enum Step: Equatable { case cancelled, wait, prepareShutdown, install }

    static func nextStep(isSafe: Bool, shutdownPrepared: Bool, cancelled: Bool) -> Step {
        if cancelled { return .cancelled }
        if !isSafe { return .wait }
        return shutdownPrepared ? .install : .prepareShutdown
    }

    @MainActor static func prepare(
        isSafeToInstall: @escaping @MainActor () -> Bool,
        canPrepareShutdown: (@MainActor () -> Bool)? = nil,
        requestGracefulShutdown: @escaping @MainActor () async -> Void,
        onStep: @escaping @MainActor (Step) -> Void = { _ in },
        sleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(nanoseconds: 1_000_000_000) }
    ) async -> Bool {
        var shutdownPrepared = false
        var previous: Step?
        while !Task.isCancelled {
            // A cancellable settings read need not finish before the host is
            // allowed to cancel it. Installation still requires the full drain.
            let ready = shutdownPrepared ? isSafeToInstall() : (canPrepareShutdown ?? isSafeToInstall)()
            let step = nextStep(isSafe: ready, shutdownPrepared: shutdownPrepared, cancelled: Task.isCancelled)
            if previous != step || step == .wait { previous = step; onStep(step) }
            // The progress callback can reenter the host and cancel this task.
            guard !Task.isCancelled else { return false }
            switch step {
            case .cancelled: return false
            case .wait:
                do { try await sleep() }
                catch { return false }
            case .prepareShutdown:
                guard (canPrepareShutdown ?? isSafeToInstall)() else { continue }
                await requestGracefulShutdown()
                shutdownPrepared = true
            case .install:
                // Check again after the async shutdown and after any progress callback.
                if isSafeToInstall() { return !Task.isCancelled }
            }
        }
        return false
    }
}

/// Downloaded bytes do not imply a scheduled install. Sparkle's user-choice
/// contract keeps a dismissed download, but only the installing stage installs on quit.
struct NativeAppUpdateInstallationIntent {
    enum Choice { case install, dismiss, skip }
    enum Stage { case notDownloaded, downloaded, installing }
    private(set) var pending = false
    mutating func schedule() { pending = true }
    mutating func cancel() { pending = false }
    mutating func choose(_ choice: Choice, stage: Stage) {
        switch choice {
        case .skip: pending = false
        case .dismiss: pending = stage == .installing
        case .install: pending = stage != .notDownloaded
        }
    }
}

/// Reusable main-bundle updater. Keep this instance alive for the application's lifetime.
///
/// The host must include calls, handoffs, playback and operation drains in `isSafeToInstall`.
/// `requestGracefulShutdown` must be idempotent, quiesce new work and await its drains; it
/// must not terminate the process. Sparkle owns application relaunch, not this core.
///
/// Sparkle 2.10 may bypass the relaunch delegate on an ordinary quit (or a previously
/// deferred relaunch). The host's termination delegate must also await
/// `prepareForTermination()` before approving termination, including installs on quit.
@MainActor final class NativeAppUpdater: NSObject {
    var onChange: (@MainActor () -> Void)?

    private let info: [String: Any]
    private let configuration: NativeAppUpdateConfiguration?
    private let configurationError: String?
    private let isSafeToInstall: @MainActor () -> Bool
    private let canPrepareShutdown: @MainActor () -> Bool
    private let installationBlocker: @MainActor () -> String?
    private let requestGracefulShutdown: @MainActor () async -> Void
    private var status = "not_started"
    private var statusDetail = "The updater has not started."
    private var lastError = ""
    private var waitingReason = ""
    private var started = false
    private var installationTask: Task<Void, Never>?
    private var installationID: UUID?
    private var installationIntent = NativeAppUpdateInstallationIntent()
    var requiresSafeTermination: Bool { installationIntent.pending || installationTask != nil }
    var postponingInstallation: Bool { installationTask != nil }
    #if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []
    private var noUpdateError: NSError?
    #endif

    init(
        isSafeToInstall: @escaping @MainActor () -> Bool,
        canPrepareShutdown: (@MainActor () -> Bool)? = nil,
        installationBlocker: @escaping @MainActor () -> String? = { nil },
        requestGracefulShutdown: @escaping @MainActor () async -> Void
    ) {
        let info = Bundle.main.infoDictionary ?? [:]
        self.info = info
        do {
            let parsed = try NativeAppUpdateConfiguration.read(info: info)
            configuration = parsed
            configurationError = parsed == nil ? "Updates are unconfigured: SUFeedURL and SUPublicEDKey are required." : nil
        } catch {
            configuration = nil
            configurationError = error.localizedDescription
        }
        self.isSafeToInstall = isSafeToInstall
        self.canPrepareShutdown = canPrepareShutdown ?? isSafeToInstall
        self.installationBlocker = installationBlocker
        self.requestGracefulShutdown = requestGracefulShutdown
        super.init()
    }

    deinit { installationTask?.cancel() }

    /// Read-only and always current; polling never starts Sparkle or a network request.
    var snapshot: [String: Any] {
        var canCheck = false
        var canSetPreferences = false
        var canSetDownloads = false
        var checks = storedBoolean("SUEnableAutomaticChecks")
        var downloads = storedBoolean("SUAutomaticallyUpdate")
        if NativeAppUpdateConfiguration.strictBoolean(info["SUAllowsAutomaticUpdates"]) == false { downloads = false }
        var frameworkAvailable = false
        #if canImport(Sparkle)
        frameworkAvailable = true
        if let updater = controller?.updater {
            // Read Sparkle itself, including stored user preferences and policy restrictions.
            checks = updater.automaticallyChecksForUpdates
            downloads = updater.automaticallyDownloadsUpdates
            canSetPreferences = started && configuration != nil
            canCheck = canSetPreferences && updater.canCheckForUpdates
            canSetDownloads = canSetPreferences && updater.allowsAutomaticUpdates
        }
        #endif
        let effectiveStatus: String
        let detail: String
        let error: String
        if configuration == nil {
            effectiveStatus = "unconfigured"
            detail = "Updates are unavailable until this app has a valid release feed and signing key."
            error = configurationError ?? detail
        } else if !frameworkAvailable {
            effectiveStatus = "unavailable"
            detail = "This build does not include the Sparkle update framework."
            error = detail
        } else {
            effectiveStatus = status; detail = statusDetail; error = lastError
        }
        return [
            "configured": configuration != nil, "framework_available": frameworkAvailable,
            "can_check": canCheck, "can_set_automatic": canSetPreferences, "can_set_downloads": canSetDownloads,
            "automatically_checks": checks, "automatically_downloads": downloads,
            "current_version": (info["CFBundleShortVersionString"] as? String).map { $0 as Any } ?? NSNull(),
            "current_build": (info["CFBundleVersion"] as? String).map { $0 as Any } ?? NSNull(),
            "status": effectiveStatus, "status_detail": detail, "waiting_reason": waitingReason, "error": error
        ]
    }

    func start() {
        guard configuration != nil, !started else { return }
        #if canImport(Sparkle)
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        // Privacy policy is independent of the user's automatic-check/download choices.
        updater.sendsSystemProfile = false
        observe(updater)
        do {
            // Use SPUUpdater's throwing start API to expose errors without a delayed alert.
            try updater.start()
            started = true
            setStatus("ready", detail: "The updater is ready; no update check has completed yet.")
        } catch {
            observations.removeAll()
            self.controller = nil
            setStatus("error", detail: "The updater could not start.", error: error.localizedDescription)
        }
        #endif
    }

    /// IPC contract: action plus `enabled: true/false` for either preference action.
    func perform(request: [String: Any]) {
        guard let action = NativeAppUpdateAction.parse(request) else {
            reject("Unknown update action or missing/invalid enabled boolean."); return
        }
        guard configuration != nil else { onChange?(); return }
        start()
        #if canImport(Sparkle)
        guard started, let controller else { return }
        let updater = controller.updater
        switch action {
        case .check:
            guard updater.canCheckForUpdates else { reject("Sparkle cannot check for updates at this time."); return }
            noUpdateError = nil
            setStatus("checking", detail: "Checking the configured release feed.")
            controller.checkForUpdates(nil)
        case .automatic(let enabled):
            updater.automaticallyChecksForUpdates = enabled
            lastError = ""; onChange?()
        case .downloads(let enabled):
            guard !enabled || updater.allowsAutomaticUpdates else {
                reject("Sparkle does not currently allow automatic downloads."); return
            }
            updater.automaticallyDownloadsUpdates = enabled
            lastError = ""; onChange?()
        }
        #else
        onChange?()
        #endif
    }

    /// Host termination hook, also required for Sparkle's install-on-quit path. A cancelled
    /// caller receives false and must not approve termination. This never terminates the app.
    func prepareForTermination() async -> Bool {
        await NativeAppUpdateSafetyPolicy.prepare(
            isSafeToInstall: isSafeToInstall, canPrepareShutdown: canPrepareShutdown,
            requestGracefulShutdown: requestGracefulShutdown
        )
    }

    /// Preserve Sparkle's install-on-quit scheduler. Downloading in the
    /// background must not request an immediate restart of the running app.
    func scheduleInstallationOnQuit() -> Bool {
        installationIntent.schedule()
        return false
    }

    private func storedBoolean(_ key: String) -> Bool {
        if let value = UserDefaults.standard.object(forKey: key) {
            return NativeAppUpdateConfiguration.strictBoolean(value) ?? false
        }
        return NativeAppUpdateConfiguration.strictBoolean(info[key]) ?? false
    }

    private func setStatus(_ status: String, detail: String, error: String = "") {
        self.status = status; statusDetail = detail; lastError = error
        waitingReason = ["waiting_for_safe_install", "preparing_shutdown"].contains(status)
            ? installationBlocker() ?? "" : ""
        onChange?()
    }

    private func reject(_ message: String) { lastError = message; onChange?() }

    #if canImport(Sparkle)
    private func observe(_ updater: SPUUpdater) {
        // Sparkle documents these properties as main-thread, KVO-compliant APIs. Notify on
        // the main actor; snapshot reads the live properties rather than an async cache.
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            },
            updater.observe(\.allowsAutomaticUpdates, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            }
        ]
    }

    private func cancelInstallationWait() {
        installationID = nil
        installationTask?.cancel()
        installationTask = nil
    }

    private func postponeInstallation(_ installHandler: @escaping () -> Void) {
        cancelInstallationWait()
        let id = UUID()
        installationID = id
        let safe = isSafeToInstall
        let prepare = canPrepareShutdown
        let shutdown = requestGracefulShutdown
        // No strong reference to this owner survives a sleep or the host's async drain.
        installationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let ready = await NativeAppUpdateSafetyPolicy.prepare(
                    isSafeToInstall: safe, canPrepareShutdown: prepare, requestGracefulShutdown: shutdown,
                    onStep: { [weak self] step in
                        guard let self, self.installationID == id else { return }
                        if step == .wait {
                            self.setStatus("waiting_for_safe_install", detail: "Installation is postponed until the host reports it is safe.")
                        } else if step == .prepareShutdown {
                            self.setStatus("preparing_shutdown", detail: "Waiting for the host to finish its graceful shutdown preparation.")
                        }
                    }
                )
                guard ready, !Task.isCancelled, let self, self.installationID == id else { return }
                self.setStatus("installing", detail: "The host is ready; handing installation back to Sparkle.")
                guard !Task.isCancelled, self.installationID == id else { return }
                // Async resumption and onChange may have allowed the host to become busy.
                // Keep the continuation and wait again instead of installing unsafely.
                guard self.isSafeToInstall() else { continue }
                self.installationID = nil
                self.installationTask = nil
                installHandler()
                return
            }
        }
    }

    private func finishWithError(_ error: Error) {
        installationIntent.cancel()
        let error = error as NSError
        if let noUpdateError, error.domain == noUpdateError.domain, error.code == noUpdateError.code {
            setStatus("no_update", detail: error.localizedDescription)
        } else {
            cancelInstallationWait()
            setStatus("error", detail: "The update operation failed.", error: error.localizedDescription)
        }
    }
    #endif
}

#if canImport(Sparkle)
// Selectors and block signatures follow SPUUpdaterDelegate.h from Sparkle 2.10.0.
extension NativeAppUpdater: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // Pin the validated bundled feed; ignore any legacy SUFeedURL user-default override.
        configuration?.feedURL.absoluteString
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        noUpdateError = nil
        setStatus("checking", detail: "Checking the configured release feed.")
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setStatus("update_available", detail: "Sparkle found an available update (\(item.displayVersionString)).")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        noUpdateError = error as NSError
        // No installable update also covers incompatible OS/hardware and unknown reasons.
        // Preserve Sparkle's explanation instead of claiming the app is up to date.
        setStatus("no_update", detail: error.localizedDescription)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        setStatus("downloading", detail: "Sparkle is downloading an update.")
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        setStatus("downloaded", detail: "Sparkle downloaded an update; it has not been installed yet.")
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) { finishWithError(error) }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        installationIntent.cancel()
        cancelInstallationWait()
        setStatus("cancelled", detail: "The update download was cancelled.")
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationIntent.schedule()
        setStatus("preparing_installation", detail: "Sparkle is preparing installation.")
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        installationIntent.schedule()
        // Also postpone when initially safe so the async host drain completes first.
        postponeInstallation(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        scheduleInstallationOnQuit()
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
        let stage: NativeAppUpdateInstallationIntent.Stage = state.stage == .installing ? .installing
            : state.stage == .downloaded ? .downloaded : .notDownloaded
        let decision: NativeAppUpdateInstallationIntent.Choice = choice == .install ? .install
            : choice == .skip ? .skip : .dismiss
        installationIntent.choose(decision, stage: stage)
        if !installationIntent.pending && choice != .install {
            cancelInstallationWait()
            setStatus("cancelled", detail: "Installation was not scheduled; the app remains available.")
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) { finishWithError(error) }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { finishWithError(error) }
        else if status == "checking" {
            setStatus("check_finished", detail: "The update cycle finished without a reported result.")
        }
        // A nil error is not proof of installation or of being on the latest version.
        // In particular, do not cancel an installation-on-quit continuation here.
    }
}
#endif
