import Foundation

enum SwitchDestination: String, Equatable { case mac, phone }

struct ActivitySample {
    var macOutput: Bool
    var macRevision: UInt64 = 0
    var macInput: Bool
    var phoneMedia: Bool
    var phoneCall: Bool
    var valid: Bool = true
}

/// Only edges after the initial observation can take audio. Active IO is a conservative
/// playback signal, not an audio level meter. Phone calls always have priority.
struct SwitchPolicy {
    private var previous: ActivitySample?
    private var macStarted: TimeInterval?
    private var idleStarted: TimeInterval?
    private var lastSwitch: TimeInterval = -.infinity
    private(set) var ownsMac = false
    private var pendingPhoneMedia = false
    var cooldown: TimeInterval = 5
    var debounce: TimeInterval = 1
    var idleDelay: TimeInterval = 10

    mutating func reset() { self = SwitchPolicy() }
    mutating func completed(_ destination: SwitchDestination, at time: TimeInterval) {
        ownsMac = destination == .mac
        // Successful Mac takeover now includes an explicitly confirmed Galaxy
        // pause. Keep that baseline so a fast new phone play is still an edge.
        if destination == .mac { previous?.phoneMedia = false }
        lastSwitch = time
        macStarted = nil
        pendingPhoneMedia = false
        idleStarted = nil
    }

    mutating func phoneConnected(at time: TimeInterval) {
        guard ownsMac else { return }
        ownsMac = false
        macStarted = nil
        pendingPhoneMedia = false
        idleStarted = nil
        lastSwitch = time
    }

    mutating func evaluate(_ sample: ActivitySample, at time: TimeInterval) -> SwitchDestination? {
        guard sample.valid else {
            // Rebaseline after gaps so reconnecting USB cannot manufacture a playback edge.
            previous = nil
            macStarted = nil
            idleStarted = nil
            pendingPhoneMedia = false
            return nil
        }
        guard let old = previous else { previous = sample; return sample.phoneCall && ownsMac ? .phone : nil }
        previous = sample
        if sample.phoneCall {
            macStarted = nil
            pendingPhoneMedia = false
            return ownsMac ? .phone : nil
        }
        if sample.macOutput && (!old.macOutput || sample.macRevision > old.macRevision) { macStarted = time }
        // A paused phone/call hands back to a still-running Mac player without
        // requiring its audio engine to close and reopen an IO stream.
        if !ownsMac && sample.macOutput && ((old.phoneMedia && !sample.phoneMedia) || (old.phoneCall && !sample.phoneCall)) {
            macStarted = time
        }
        if !sample.macOutput { macStarted = nil }
        if ownsMac && sample.phoneMedia && !old.phoneMedia { pendingPhoneMedia = true }
        if !sample.phoneMedia { pendingPhoneMedia = false }
        if !sample.macOutput && !sample.macInput {
            if idleStarted == nil { idleStarted = time }
        } else { idleStarted = nil }
        guard time - lastSwitch >= cooldown else { return nil }
        // A Mac microphone session can be a call or recording; keep it on the Mac
        // for ordinary phone media. Phone calls above can still interrupt it.
        if ownsMac && !sample.macInput {
            if pendingPhoneMedia { return .phone }
            if let idleStarted, time - idleStarted >= idleDelay { return .phone }
        }
        if !ownsMac, let start = macStarted, time - start >= debounce { return .mac }
        return nil
    }
}
