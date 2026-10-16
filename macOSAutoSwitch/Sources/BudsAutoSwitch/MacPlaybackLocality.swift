import Foundation

/// MediaRemote can mirror Spotify Connect playback on another device. An
/// explicit player state is acquisition intent only with local output evidence.
enum MacPlaybackLocality {
    static func apply(_ intent: MacPlaybackIntent, clientOutput: Bool?, anyAppOutput: Bool) -> MacPlaybackIntent {
        guard intent.isPlaying == true else { return intent }
        let playing: Bool?
        if clientOutput == true { playing = true }
        else if clientOutput == false && !anyAppOutput { playing = false }
        else { playing = nil }
        return MacPlaybackIntent(isPlaying: playing, clientID: intent.clientID,
            revision: intent.revision, observedAt: intent.observedAt, reportedIsPlaying: intent.reportedIsPlaying)
    }
}
