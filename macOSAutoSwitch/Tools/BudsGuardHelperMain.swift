import Foundation
import Darwin

// Like the standalone probes, this entrypoint supplies localization without
// pulling AutoSwitchModel or AndroidBridge into the dedicated executable.
func L(_ portuguese: String, _ english: String) -> String {
    Locale.preferredLanguages.first?.hasPrefix("pt") == true ? portuguese : english
}

enum NativeSwitchEvidence {
    static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

@main enum BudsGuardHelperMain {
    static func main() {
        if MainActor.assumeIsolated({ NativeBudsLinkObserverHelper.runIfRequested() }) { return }
        if MainActor.assumeIsolated({ NativeBudsSettingsHelper.runIfRequested() }) { return }
        guard CommandLine.arguments.contains(SpeakerGuardEnvironment.watchdogFlag) else {
            fputs("BudsGuardHelper: watchdog invocation required\n", stderr)
            exit(64)
        }
        // The existing entrypoint validates token/owner before creating the live
        // environment, then blocks until ownership ends or recovery completes.
        SpeakerGuard.runWatchdogIfRequested()
    }
}
