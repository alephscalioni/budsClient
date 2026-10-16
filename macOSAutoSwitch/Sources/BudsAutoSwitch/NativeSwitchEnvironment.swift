import Foundation

/// All controller effects are injected. Test environments never instantiate the
/// radio, HAL, playback observer, persistent guard journal, or HUD.
@MainActor struct NativeSwitchEnvironment {
    var now: () -> TimeInterval
    var sleep: (TimeInterval) async throws -> Void
    var pairedBuds: () async throws -> [(address: String, name: String)]
    var handlers: (((SamsungMdePacket.Frame) -> Void)?, ((NativeBudsError) -> Void)?) -> Void
    var isOpen: () -> Bool
    var open: (String) async throws -> Void
    var close: () -> Void
    var send: (Data) throws -> Void
    var isArmed: () -> Bool
    var armedDevice: () -> UInt32?
    var arm: (UInt32) async throws -> Void
    var verify: () throws -> Void
    var restore: () async throws -> Void
    var startPlayback: () -> Void
    var stopPlayback: () -> Void
    var sample: () async -> MacPlaybackIntent
    var pause: () async throws -> Void
    var activity: () throws -> AudioActivity
    var defaultOutput: () -> UInt32?
    var output: (String) throws -> UInt32?
    var waitingOutput: (UInt32?) throws -> UInt32?
    var setOutput: (UInt32) async throws -> Void
    var linked: (String) async throws -> Bool
    var loadBattery: (String) -> BudsBatterySnapshot?
    var show: (String, String, BudsBatterySnapshot?, String) -> Void
    var diagnostics: () -> [String: Any] = { [:] }
    // Opt in only where a host ACL release has been validated. Legacy effect
    // harnesses can keep logical/multipoint handoff semantics with nil.
    var releaseBluetooth: ((String) async throws -> Void)? = nil
    var outputBelongsToBuds: ((UInt32, String) -> Bool)? = nil
    var remoteReleaseSettleDelay: TimeInterval = 0
    /// Passive snapshot only. Nil preserves unknown profile state; live() does
    /// not infer HFP connectivity from the MDE stream or create a profile.
    var continuityProfiles: ((String, UUID) -> NativeSamsungBudsProfileObservation?)? = nil
    /// Completed presentation facts, independent of audio/peer ownership effects.
    /// Nil retains the legacy `show` callback for existing effect harnesses.
    /// Hosts supplying this callback must forward it to the same HUD as the
    /// passive monitor's onEvent; it replaces, rather than supplements, `show`.
    var banner: ((NativeConnectionBannerEvent, BudsBatterySnapshot?) -> Void)? = nil

    static func live() -> Self {
        let control = NativeBudsTransport(), guardState = SpeakerGuard()
        let player = NativeSwitchPlayer()
        return Self(now: { NativeSwitchEvidence.now }, sleep: { try await Task.sleep(for: .seconds($0)) },
            pairedBuds: { try await MacAudio.pairedBuds() },
            handlers: { control.onFrame = $0; control.onFailure = $1 },
            isOpen: { control.isOpen }, open: { try await control.open(address: $0) },
            close: { control.close() }, send: { try control.send($0) },
            isArmed: { guardState.isArmed }, armedDevice: { guardState.armedDevice },
            arm: { try await guardState.arm($0) }, verify: { try guardState.verify() },
            restore: { try await guardState.restore() },
            startPlayback: { player.monitor = MacPlaybackIntentMonitor() },
            stopPlayback: { player.monitor = nil },
            sample: { await player.sample() },
            pause: { try await player.pause() },
            activity: { try MacAudio.activity() }, defaultOutput: { MacAudio.defaultOutput() },
            output: { try MacAudio.output(for: $0) }, waitingOutput: { try MacAudio.waitingOutput(excluding: $0) },
            setOutput: { try await MacAudio.setOutput($0) }, linked: { try await MacAudio.isBluetoothConnected($0) },
            loadBattery: { BudsBatterySnapshot.load(address: $0) },
            show: { ConnectionHUD.shared.show(name: $0, destination: $1, battery: $2, address: $3) },
            diagnostics: { control.diagnostics },
            releaseBluetooth: { _ = try await MacAudio.requestClose($0) },
            outputBelongsToBuds: { MacAudio.outputBelongsToBuds($0, address: $1) },
            remoteReleaseSettleDelay: 2,
            banner: { ConnectionHUD.shared.show(event: $0, battery: $1) })
    }
}

@MainActor private final class NativeSwitchPlayer {
    var monitor: MacPlaybackIntentMonitor?
    func sample() async -> MacPlaybackIntent {
        let raw = await monitor?.sample() ?? MacPlaybackIntent(isPlaying: nil, clientID: nil, revision: 0)
        guard raw.isPlaying == true, let client = raw.clientID else { return raw }
        do {
            let output = try MacAudio.playbackActivity(client: client)
            return MacPlaybackLocality.apply(raw, clientOutput: output.clientOutput, anyAppOutput: output.anyAppOutput)
        } catch {
            return MacPlaybackIntent(isPlaying: nil, clientID: client, revision: raw.revision,
                observedAt: raw.observedAt, reportedIsPlaying: raw.reportedIsPlaying)
        }
    }
    func pause() async throws {
        let local = await sample()
        // A Spotify Connect control session must not pause the phone to prove
        // the absence of Mac audio. Only a locally producing client is paused.
        if local.isPlaying == false { return }
        guard local.isPlaying == true, let client = local.clientID else {
            throw PlaybackControlError(message: "Não foi possível identificar reprodução local no Mac para pausar.")
        }
        do { _ = try await monitor?.pauseForHandoff(expectedClient: client, requireLocalOutput: true) }
        catch {
            // A same-client Connect migration can end local IO while awaiting
            // the command. Re-read local silence without fabricating an MR ACK.
            if (await sample()).isPlaying == false { return }
            throw error
        }
    }
}
