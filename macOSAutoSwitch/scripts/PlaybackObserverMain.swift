// Appended to MacPlaybackIntent.swift by build-app.sh; run with Apple's Swift interpreter.
@MainActor final class PlaybackObserverCommands {
    var buffer = Data()
    private let pauses = PlaybackPauseCoordinator<PlaybackPauseResult>()
    func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count < 65_536 else { buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: String],
                  row["command"] == "pause", let client = row["client"], !client.isEmpty, client.count < 512,
                  let id = row["id"], UUID(uuidString: id) != nil else { continue }
            Task { @MainActor in
                do {
                    let requireLocal = row["local_output"] == "required"
                    let result = try await pauses.perform(client: requireLocal ? "local:\(client)" : client) {
                        try await MacPlaybackIntentMonitor.pauseNativeObservation(client: client, requireLocalOutput: requireLocal)
                    }
                    reply(id, paused: result.paused, observation: result.observation)
                }
                catch { reply(id, error: "Mac pause failed or could not be verified") }
            }
        }
    }
    func reply(_ id: String, paused: Bool = false, observation: PlaybackObservation? = nil, error: String? = nil) {
        var row: [String: Any] = ["control": id, "ok": error == nil, "paused": paused]
        if error == nil, let observation {
            row["playing"] = observation.playing
            row["client"] = observation.client
            row["uptime"] = observation.uptime
        }
        if let error { row["error"] = error }
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
    }
}
Task { @MainActor in
    let monitor = MacPlaybackIntentMonitor()
    let commands = PlaybackObserverCommands()
    FileHandle.standardInput.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { exit(0) }
        Task { @MainActor in commands.consume(data) }
    }
    let owner = ProcessInfo.processInfo.environment["BUDS_PLAYBACK_OWNER_PID"].flatMap(Int32.init)
    while owner == nil || kill(owner!, 0) == 0 {
        let reading = await monitor.sample()
        var row: [String: Any] = ["revision": reading.revision]
        if let uptime = reading.observedAt { row["uptime"] = uptime }
        if let playing = reading.isPlaying { row["playing"] = playing }
        if let client = reading.clientID { row["client"] = client }
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
            print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
        try? await Task.sleep(for: .milliseconds(200))
    }
    exit(0)
}
RunLoop.main.run()
