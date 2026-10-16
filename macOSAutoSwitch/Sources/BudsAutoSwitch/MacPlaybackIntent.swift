import Foundation
import Darwin

struct MacPlaybackIntent {
    let isPlaying: Bool?
    let clientID: String?
    let revision: UInt64
    let observedAt: TimeInterval?
    /// The player's report before local-HAL filtering. A route initialization
    /// gap is not an explicit player pause and cannot create new acquisition.
    let reportedIsPlaying: Bool?

    init(isPlaying: Bool?, clientID: String?, revision: UInt64, observedAt: TimeInterval? = nil,
         reportedIsPlaying: Bool? = nil) {
        self.isPlaying = isPlaying
        self.clientID = clientID
        self.revision = revision
        self.observedAt = observedAt
        self.reportedIsPlaying = reportedIsPlaying ?? isPlaying
    }
}

struct PlaybackControlError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

typealias PlaybackPauseResult = (paused: Bool, observation: PlaybackObservation)

/// A caller owns only its wait. The unstructured transaction survives cancellation
/// so cleanup can join it, even when there are temporarily no waiters.
@MainActor final class PlaybackPauseCoordinator<Value> {
    private struct Owner {
        let id: UUID
        let client: String?
        var waiters: [UUID: CheckedContinuation<Result<Value, Error>, Never>] = [:]
    }
    private var owner: Owner?
    private var completed: (id: UUID, client: String?, result: Result<Value, Error>)?
    private let retainUnclaimedResult: Bool
    var isBusy: Bool { owner != nil }
    var waiterCount: Int { owner?.waiters.count ?? 0 }

    init(retainUnclaimedResult: Bool = false) { self.retainUnclaimedResult = retainUnclaimedResult }

    func perform(client: String? = nil, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if let completed {
            guard completed.client == client else {
                throw PlaybackControlError(message: "An unclaimed pause belongs to a different Mac player")
            }
            // Cleanup can arrive after an orphaned transaction has completed. Keep
            // its receipt until a non-canceled caller consumes it, instead of pausing
            // whatever newer player happens to be visible by then.
            try Task.checkCancellation()
            self.completed = nil
            return try completed.result.get()
        }
        if let owner, owner.client != client {
            throw PlaybackControlError(message: "A pause for a different Mac player is pending")
        }
        let waiter = UUID()
        var transactionID: UUID?
        let result: Result<Value, Error> = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: .failure(CancellationError())); return }
                let startsOwner = owner == nil
                if startsOwner { owner = Owner(id: UUID(), client: client) }
                transactionID = owner!.id
                owner!.waiters[waiter] = continuation
                if startsOwner {
                    let id = owner!.id
                    Task { @MainActor in
                        let result: Result<Value, Error>
                        do { result = .success(try await operation()) }
                        catch { result = .failure(error) }
                        guard let owner = self.owner, owner.id == id else { return }
                        if self.retainUnclaimedResult { self.completed = (id, owner.client, result) }
                        self.owner = nil // Release ownership before waking any caller.
                        for continuation in owner.waiters.values { continuation.resume(returning: result) }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.owner?.waiters.removeValue(forKey: waiter)?.resume(returning: .failure(CancellationError()))
            }
        }
        // Cancellation can race successful completion and the queued cancellation
        // handler. A canceled caller must neither report success nor consume receipt.
        try Task.checkCancellation()
        if completed?.id == transactionID { completed = nil }
        return try result.get()
    }
}

enum PlaybackPauseBudget {
    // Whole operations, not a per-read timeout multiplied by eight polls.
    static let native: TimeInterval = 2.8
    static let reply: TimeInterval = 3.5
    static let monitor: TimeInterval = 3.8
}

/// Unlike a task group, this race does not wait for a non-cooperative getter after
/// timeout. All operations must fence side effects after every suspension.
@MainActor enum PlaybackDeadline {
    typealias Sleep = @MainActor (TimeInterval) async throws -> Void
    static func sleep(_ seconds: TimeInterval) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
    static func run<Value>(seconds: TimeInterval, sleep: @escaping Sleep = PlaybackDeadline.sleep,
                           now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                           onAbort: @escaping @MainActor () -> Void = {},
                           operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let deadline = now() + seconds
        let race = Race<Value>(onAbort: onAbort)
        let value: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                race.continuation = continuation
                race.operation = Task { @MainActor in
                    guard now() < deadline else {
                        race.abort(PlaybackControlError(message: "Mac pause operation timed out")); return
                    }
                    do {
                        let result = try await operation()
                        if now() >= deadline { race.abort(PlaybackControlError(message: "Mac pause operation timed out")) }
                        else { race.finish(.success(result)) }
                    } catch { race.finish(.failure(error)) }
                }
                race.timer = Task { @MainActor in
                    do {
                        try await sleep(max(0, deadline - now()))
                        try Task.checkCancellation()
                        race.abort(PlaybackControlError(message: "Mac pause operation timed out"))
                    } catch { /* A completed operation cancels its timer. */ }
                }
            }
        } onCancel: {
            Task { @MainActor in race.abort(CancellationError()) }
        }
        try Task.checkCancellation()
        return value
    }
    @MainActor private final class Race<Value> {
        var continuation: CheckedContinuation<Value, Error>?
        var operation: Task<Void, Never>?
        var timer: Task<Void, Never>?
        let onAbort: @MainActor () -> Void
        init(onAbort: @escaping @MainActor () -> Void) { self.onAbort = onAbort }
        func abort(_ error: Error) {
            guard continuation != nil else { return }
            operation?.cancel()
            onAbort()
            finish(.failure(error))
        }
        func finish(_ result: Result<Value, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timer?.cancel()
            timer = nil
            operation = nil
            continuation.resume(with: result)
        }
    }
}

/// Pure, injectable verification used by both native adapters. Unknowns never
/// confirm a pause; a different client stops verification without another command.
@MainActor enum PlaybackPauseVerification {
    static func run(client: String, now: @escaping @MainActor () -> TimeInterval,
                    read: @escaping @MainActor () async -> PlaybackReading,
                    sendPause: @escaping @MainActor (TimeInterval) async throws -> Bool,
                    sleep: @escaping PlaybackDeadline.Sleep = PlaybackDeadline.sleep) async throws -> PlaybackPauseResult {
        let started = now()
        return try await PlaybackDeadline.run(seconds: PlaybackPauseBudget.native, sleep: sleep, now: now) {
            try Task.checkCancellation()
            let before = await read()
            try Task.checkCancellation()
            guard let observation = before.observation, observation.client == client,
                  observation.uptime >= started, observation.uptime <= now(), now() - observation.uptime < 2 else {
                throw PlaybackControlError(message: "Mac player changed or playback state is unavailable")
            }
            guard observation.playing else { return (false, observation) }
            guard now() < started + PlaybackPauseBudget.native else {
                throw PlaybackControlError(message: "Mac pause operation timed out")
            }
            let sentAt = now()
            // The native adapter fences a queued command against this same deadline.
            guard try await sendPause(started + PlaybackPauseBudget.native) else {
                throw PlaybackControlError(message: "Mac player did not accept the pause command")
            }
            try Task.checkCancellation()
            while true {
                try await sleep(0.15)
                try Task.checkCancellation()
                let after = await read()
                try Task.checkCancellation()
                guard now() < started + PlaybackPauseBudget.native else {
                    throw PlaybackControlError(message: "Mac pause operation timed out")
                }
                if let changed = after.client, changed != client {
                    throw PlaybackControlError(message: "Mac player changed during pause")
                }
                var verification = PlaybackObservationCache()
                if verification.acceptPauseReply(ok: true, paused: true, observation: after.observation,
                                                  client: client, requestedAt: sentAt, now: now()),
                   let observation = after.observation { return (true, observation) }
            }
        }
    }
}

/// Experimental MediaRemote adapter. Pauses the current player during Galaxy handoff.
@MainActor
final class MacPlaybackIntentMonitor {
    private var state = PlaybackIntentState()
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<(native: PlaybackReading, interpreted: PlaybackReading?), Never>?
    private var generation: UInt64 = 0
    private var appliedGeneration: UInt64 = 0
    private var interpreter: InterpretedPlaybackReader?
    private let pauses = PlaybackPauseCoordinator<Bool>(retainUnclaimedResult: true)
    private var readOverride: (@MainActor () async -> PlaybackReading)?
    private var pauseOverride: (@MainActor (String) async throws -> PlaybackPauseResult)?
    private var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var deadlineSleep: PlaybackDeadline.Sleep = PlaybackDeadline.sleep

    init(read: @escaping @MainActor () async -> PlaybackReading,
         pause: @escaping @MainActor (String) async throws -> PlaybackPauseResult,
         now: @escaping @MainActor () -> TimeInterval,
         sleep: @escaping PlaybackDeadline.Sleep) {
        readOverride = read
        pauseOverride = pause
        self.now = now
        deadlineSleep = sleep
    }

    init() {
        if ProcessInfo.processInfo.environment["BUDS_PLAYBACK_OBSERVER"] != "1" {
            interpreter = InterpretedPlaybackReader()
            interpreter?.onVerifiedPause = { [weak self] observation, latest in
                guard let self else { return }
                let now = self.now()
                self.state.observe(PlaybackReading(observation), source: .interpreted, at: now)
                if let latest { self.state.observe(latest, source: .interpreted, at: now) }
                // Publish verification before waking the command's caller or any
                // sample waiting on an older native/interpreted request.
                self.pending = nil
                self.generation &+= 1
            }
        }
        // Notifications prompt a fresh read, never create an edge themselves.
        for name in ["kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                     "kMRMediaRemoteNowPlayingInfoDidChangeNotification"] {
            observers.append(NotificationCenter.default.addObserver(
                forName: Notification.Name(name), object: nil, queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in _ = await self?.sample() }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func sample() async -> MacPlaybackIntent {
        if pending == nil {
            generation &+= 1
            pending = Task {
                let native: PlaybackReading
                if let readOverride { native = await readOverride() }
                else { native = await MediaRemoteReader.read() }
                // Even a valid native read can predate an interpreted confirmation.
                let interpreted: PlaybackReading?
                if native.observation != nil { interpreted = interpreter?.cachedReading() }
                else { interpreted = await interpreter?.read() }
                return (native, interpreted)
            }
        }
        let currentGeneration = generation
        let reading = await pending!.value
        // A pause invalidates requests that were already in flight. Their callers
        // must join a fresh sample rather than publish a pre-command observation.
        if currentGeneration != generation { return await sample() }
        // Concurrent callers share one request and apply its observation once.
        if currentGeneration > appliedGeneration {
            appliedGeneration = currentGeneration
            pending = nil
            state.sample(native: reading.native, interpreted: reading.interpreted,
                         at: now())
        }
        return state.current(at: now())
    }

    @discardableResult func pauseForHandoff(expectedClient: String? = nil, requireLocalOutput: Bool = false) async throws -> Bool {
        // Join before sampling: an in-flight pause may have invalidated the cache,
        // or a newer player may already be visible. Neither warrants a second pause.
        try await pauses.perform(client: expectedClient.map { requireLocalOutput ? "local:\($0)" : $0 }) {
            defer {
                self.pending = nil
                self.generation &+= 1
            }
            let deadline = self.now() + PlaybackPauseBudget.monitor
            return try await PlaybackDeadline.run(seconds: PlaybackPauseBudget.monitor, sleep: self.deadlineSleep, now: self.now, onAbort: {
                self.interpreter?.invalidate()
            }) {
                let current = await self.sample()
                try Task.checkCancellation()
                guard self.now() < deadline else {
                    throw PlaybackControlError(message: "Mac pause operation timed out")
                }
                guard let playing = current.isPlaying, let client = current.clientID else {
                    throw PlaybackControlError(message: "Cannot verify the Mac player for pause")
                }
                guard expectedClient == nil || expectedClient == client else {
                    throw PlaybackControlError(message: "Mac player changed before local pause")
                }
                guard playing else { return false }
                let requestedAt = self.now()
                self.state.beginPause(at: requestedAt)
                self.pending = nil
                self.generation &+= 1
                let result: PlaybackPauseResult
                let source: PlaybackObservationSource
                if let pauseOverride = self.pauseOverride {
                    result = try await pauseOverride(client)
                    source = .native
                } else if let interpreter = self.interpreter {
                    result = try await interpreter.pauseObservation(client: client, requireLocalOutput: requireLocalOutput)
                    source = .interpreted
                } else {
                    result = try await Self.pauseNativeObservation(client: client, requireLocalOutput: requireLocalOutput)
                    source = .native
                }
                try Task.checkCancellation()
                guard self.state.acceptPause(result.observation, client: client, requestedAt: requestedAt,
                                             source: source, at: self.now()) else {
                    throw PlaybackControlError(message: "Mac pause reply has no fresh verified player observation")
                }
                if let latest = self.interpreter?.cachedReading() {
                    self.state.observe(latest, source: .interpreted, at: self.now())
                }
                return result.paused
            }
        }
    }

    // Used by the persistent observer process too: verify the current client before
    // sending an explicit pause (never a toggle), then verify that playback stopped.
    static func pauseNative(client: String) async throws -> Bool {
        (try await pauseNativeObservation(client: client)).paused
    }

    static func pauseNativeObservation(client: String, requireLocalOutput: Bool = false) async throws -> (paused: Bool, observation: PlaybackObservation) {
        try await PlaybackPauseVerification.run(client: client, now: { ProcessInfo.processInfo.systemUptime },
                                               read: { await MediaRemoteReader.read() }, sendPause: { deadline in
            try await MediaRemoteReader.sendPause(until: deadline, localClient: requireLocalOutput ? client : nil)
        })
    }
}

/// Kept separate so revision semantics can be checked without native APIs/hardware.
struct PlaybackIntentHistory {
    private(set) var revision: UInt64 = 0
    private var lastPlaying: Bool?
    private var lastClient: String?
    private var lastRemoteRevision: UInt64?
    private var lastSource: PlaybackObservationSource?

    mutating func observe(playing: Bool?, client: String?, item: String?, observedRevision: UInt64? = nil,
                          source: PlaybackObservationSource? = nil) {
        guard let playing, let client else { return }
        // The first known player establishes the baseline, including startup while playing.
        let resumed = lastPlaying == false && playing
        let changedClient = lastClient != nil && lastClient != client
        let resumedBetweenPolls: Bool
        if let previous = lastRemoteRevision, let observedRevision {
            resumedBetweenPolls = playing && source != nil && lastSource == source && observedRevision > previous
        } else { resumedBetweenPolls = false }
        if resumed || changedClient || resumedBetweenPolls { revision &+= 1 }
        lastPlaying = playing
        lastClient = client
        lastRemoteRevision = observedRevision
        lastSource = source
    }

    mutating func confirmResume(since baseline: UInt64) {
        // A late pause reply can prove that an already newer playing row resumed.
        // Do not double count a source revision or client edge accepted meanwhile.
        if revision == baseline { revision &+= 1 }
    }
}

enum PlaybackObservationSource: Equatable { case native, interpreted }

/// One timestamp watermark for both readers and verified controls. Retain it even
/// after expiration/unknowns so a delayed fallback cannot create a playback edge.
struct PlaybackIntentState {
    private var history = PlaybackIntentHistory()
    private var latest: PlaybackReading?
    private var minimumUptime: TimeInterval = 0
    private var pauseBaseline: (uptime: TimeInterval, revision: UInt64)?

    mutating func beginPause(at uptime: TimeInterval) {
        minimumUptime = max(minimumUptime, uptime)
        pauseBaseline = (uptime, history.revision)
    }

    mutating func sample(native: PlaybackReading, interpreted: PlaybackReading?, at now: TimeInterval) {
        let candidates: [(PlaybackReading, PlaybackObservationSource)] =
            [(native, .native)] + (interpreted.map { [($0, .interpreted)] } ?? [])
        let fresh = candidates.filter { isFresh($0.0, at: now) }
        // A failed native getter is not evidence against a usable fallback.
        let explicit = fresh.filter { $0.0.observation != nil }
        if let newest = (explicit.isEmpty ? fresh : explicit).max(by: {
            $0.0.observedAt! < $1.0.observedAt!
        }) {
            observe(newest.0, source: newest.1, at: now)
        }
    }

    @discardableResult mutating func observe(_ reading: PlaybackReading, source: PlaybackObservationSource,
                                            at now: TimeInterval) -> Bool {
        let previousUptime = latest?.observedAt
        guard isFresh(reading, at: now), let uptime = reading.observedAt,
              previousUptime.map({ uptime > $0 }) ?? true else { return false }
        if reading.observation != nil {
            latest = reading
            history.observe(playing: reading.playing, client: reading.client, item: reading.item,
                            observedRevision: reading.observedRevision, source: source)
        } else {
            // Timestamped unknowns can hide older state, but never establish a
            // pause/resume or discard the ordering watermark/history baseline.
            latest = PlaybackReading(observedAt: uptime)
        }
        return true
    }

    @discardableResult mutating func acceptPause(_ observation: PlaybackObservation, client: String,
                                                requestedAt: TimeInterval, source: PlaybackObservationSource,
                                                at now: TimeInterval) -> Bool {
        var verification = PlaybackObservationCache()
        guard verification.acceptPauseReply(ok: true, paused: true, observation: observation,
                                             client: client, requestedAt: requestedAt, now: now) else { return false }
        // A newer row always retains the global watermark. A verified stop before
        // that row can still prove a resume, without replaying the older state.
        if let latest, let uptime = latest.observedAt, uptime > observation.uptime,
           latest.playing == true, latest.client == client,
           let baseline = pauseBaseline, baseline.uptime == requestedAt {
            history.confirmResume(since: baseline.revision)
        }
        observe(PlaybackReading(observation), source: source, at: now)
        return true
    }

    func current(at now: TimeInterval) -> MacPlaybackIntent {
        let reading = latest.flatMap { isFresh($0, at: now) ? $0 : nil }
        return MacPlaybackIntent(isPlaying: reading?.playing, clientID: reading?.client,
                                 revision: history.revision, observedAt: reading?.observedAt)
    }

    private func isFresh(_ reading: PlaybackReading, at now: TimeInterval) -> Bool {
        guard let uptime = reading.observedAt else { return false }
        return uptime.isFinite && now.isFinite && uptime >= minimumUptime && uptime <= now && now - uptime < 2
    }
}

/// Uptime is captured when a native read starts, never when its output is emitted.
/// This keeps delayed/overlapping reads from appearing newer than a verified pause.
struct PlaybackObservation: Equatable {
    let playing: Bool
    let client: String
    let uptime: TimeInterval
    var revision: UInt64? = nil
}

/// Pure ordering/freshness policy shared by periodic rows and control replies.
struct PlaybackObservationCache {
    private(set) var latest: PlaybackObservation?
    private var minimumUptime: TimeInterval = 0

    mutating func beginPause(at uptime: TimeInterval) {
        minimumUptime = max(minimumUptime, uptime)
        if let latest, latest.uptime < minimumUptime { self.latest = nil }
    }

    func current(at now: TimeInterval) -> PlaybackObservation? {
        guard let latest, isFresh(latest, at: now) else { return nil }
        return latest
    }

    @discardableResult mutating func observe(_ observation: PlaybackObservation, at now: TimeInterval) -> Bool {
        guard isFresh(observation, at: now),
              latest.map({ observation.uptime > $0.uptime }) ?? true else { return false }
        latest = observation
        return true
    }

    // A valid confirmation can be older than an already received resume/client
    // change. Acknowledge the command, but keep that newer playback observation.
    mutating func acceptPauseReply(ok: Bool, paused: Bool?, observation: PlaybackObservation?,
                                  client: String, requestedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard ok, paused != nil, let observation, !observation.playing,
              observation.client == client, observation.uptime >= requestedAt,
              isFresh(observation, at: now) else { return false }
        observe(observation, at: now)
        return true
    }

    private func isFresh(_ observation: PlaybackObservation, at now: TimeInterval) -> Bool {
        !observation.client.isEmpty && observation.uptime.isFinite && now.isFinite
            && observation.uptime >= minimumUptime && observation.uptime <= now
            && now - observation.uptime < 2
    }
}

struct PlaybackReading {
    var playing: Bool?
    var client: String?
    var item: String?
    var observedRevision: UInt64?
    var observedAt: TimeInterval?
    static let unknown = PlaybackReading()

    init(playing: Bool? = nil, client: String? = nil, item: String? = nil,
         observedRevision: UInt64? = nil, observedAt: TimeInterval? = nil) {
        self.playing = playing
        self.client = client
        self.item = item
        self.observedRevision = observedRevision
        self.observedAt = observedAt
    }

    init(_ observation: PlaybackObservation) {
        self.init(playing: observation.playing, client: observation.client,
                  observedRevision: observation.revision, observedAt: observation.uptime)
    }

    var observation: PlaybackObservation? {
        guard let playing, let client, !client.isEmpty, let observedAt else { return nil }
        return PlaybackObservation(playing: playing, client: client, uptime: observedAt, revision: observedRevision)
    }
}

private enum MediaRemoteReader {
    // ABI declarations match the linked source headers documented in mac-intent-result.md.
    typealias Playing = @convention(c) (DispatchQueue, @escaping @convention(block) (Bool) -> Void) -> Void
    typealias Info = @convention(c) (DispatchQueue, @escaping @convention(block) (NSDictionary?) -> Void) -> Void
    typealias Client = @convention(c) (DispatchQueue, @escaping @convention(block) (AnyObject?) -> Void) -> Void
    typealias Bundle = @convention(c) (AnyObject) -> Unmanaged<CFString>?
    typealias Register = @convention(c) (DispatchQueue) -> Void
    // C Boolean MRMediaRemoteSendCommand(MRMediaRemoteCommand, NSDictionary *).
    // Command 1 is pause in the original MediaRemote reverse-engineered header.
    typealias Command = @convention(c) (UInt32, NSDictionary?) -> Bool
    static let callbacks = DispatchQueue(label: "BudsAutoSwitch.MediaRemote.callbacks")
    static let invocations = DispatchQueue(label: "BudsAutoSwitch.MediaRemote.requests")
    // Keep the framework loaded while its asynchronous callbacks may still run.
    static let handle: UnsafeMutableRawPointer? = {
        let h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL)
        if let h, let symbol = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            unsafeBitCast(symbol, to: Register.self)(callbacks)
        }
        return h
    }()

    static func function<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    static func sendPause(until deadline: TimeInterval, localClient: String? = nil) async throws -> Bool {
        let request = CommandRequest()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                // Native invocations never block the actor that enforces the whole
                // operation deadline. A canceled/expired queued command is discarded.
                invocations.async {
                    let send = function("MRMediaRemoteSendCommand", as: Command.self)
                    guard request.maySend(until: deadline) else { request.finish(.failure(CancellationError())); return }
                    if let localClient {
                        guard (try? MacPlaybackProcessActivity.read(client: localClient).clientOutput) == true else {
                            request.finish(.failure(PlaybackControlError(message: "Local playback ended before pause dispatch"))); return
                        }
                        guard request.maySend(until: deadline) else { request.finish(.failure(CancellationError())); return }
                    }
                    // MediaRemote targets the global player. It has no atomic
                    // compare-client-and-pause API; a native in-flight send cannot be retracted.
                    request.finish(.success(send?(1, nil) ?? false))
                }
            }
        } onCancel: { request.cancel() }
    }

    private final class CommandRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var canceled = false
        private var continuation: CheckedContinuation<Bool, Error>?
        func install(_ continuation: CheckedContinuation<Bool, Error>) {
            lock.lock()
            if canceled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            lock.unlock()
        }
        func maySend(until deadline: TimeInterval) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return !canceled && ProcessInfo.processInfo.systemUptime < deadline
        }
        func cancel() {
            lock.lock()
            canceled = true
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
        func finish(_ result: Result<Bool, Error>) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(with: result)
        }
    }

    static func read() async -> PlaybackReading {
        await withCheckedContinuation { continuation in
            let request = Request(continuation)
            // Deadline is independent of native invocation; no semaphore/main-queue waits.
            callbacks.asyncAfter(deadline: .now() + 0.8) { request.finish(timedOut: true) }
            invocations.async {
                guard let playing = function("MRMediaRemoteGetNowPlayingApplicationIsPlaying", as: Playing.self),
                      let info = function("MRMediaRemoteGetNowPlayingInfo", as: Info.self),
                      let client = function("MRMediaRemoteGetNowPlayingClient", as: Client.self),
                      let bundle = function("MRNowPlayingClientGetBundleIdentifier", as: Bundle.self) else {
                    callbacks.async { request.finish(timedOut: true) }
                    return
                }
                let parent = function("MRNowPlayingClientGetParentAppBundleIdentifier", as: Bundle.self)
                playing(callbacks) { value in
                    request.playing = value; request.received += 1; request.finish()
                }
                info(callbacks) { value in
                    request.hasInfo = value != nil
                    request.rate = value?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber
                    request.received += 1; request.finish()
                }
                client(callbacks) { value in
                    if let value {
                        // Safari publishes through WebKit.GPU; prefer its owning app.
                        request.client = (parent?(value) ?? bundle(value))?.takeUnretainedValue() as String?
                    }
                    request.received += 1; request.finish()
                }
            }
        }
    }

    /// All fields and completion are confined to callbacks, including timeout/late replies.
    private final class Request: @unchecked Sendable {
        var playing: Bool?
        var rate: NSNumber?
        var hasInfo = false
        var client: String?
        var received = 0
        let observedAt = ProcessInfo.processInfo.systemUptime
        var continuation: CheckedContinuation<PlaybackReading, Never>?
        init(_ continuation: CheckedContinuation<PlaybackReading, Never>) { self.continuation = continuation }
        func finish(timedOut: Bool = false) {
            guard timedOut || received == 3, let continuation else { return }
            self.continuation = nil
            continuation.resume(returning: PlaybackNativeEvidence.reading(playing: playing,
                rate: rate?.doubleValue, hasInfo: hasInfo, client: client,
                observedAt: observedAt, timedOut: timedOut))
        }
    }
}

/// Pure control protocol. Continuations belong to the transaction, not to an
/// individual caller. Transport loss fails every pending control immediately.
@MainActor final class PlaybackPauseControlChannel {
    var onVerifiedPause: ((PlaybackObservation, PlaybackReading?) -> Void)?
    private struct Pending {
        let client: String
        let requestedAt: TimeInterval
        let continuation: CheckedContinuation<PlaybackPauseResult, Error>
    }
    private var controls: [String: Pending] = [:]
    private var cache = PlaybackObservationCache()
    private let now: @MainActor () -> TimeInterval
    private let sleep: PlaybackDeadline.Sleep
    var pendingCount: Int { controls.count }

    init(now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping PlaybackDeadline.Sleep = PlaybackDeadline.sleep) {
        self.now = now
        self.sleep = sleep
    }
    func cachedReading() -> PlaybackReading? { cache.current(at: now()).map { PlaybackReading($0) } }

    func request(client: String, requireLocalOutput: Bool = false, write: @escaping @MainActor (Data) throws -> Void,
                 invalidate: @escaping @MainActor () -> Void) async throws -> PlaybackPauseResult {
        let id = UUID().uuidString
        let requestedAt = now()
        var command = ["command": "pause", "client": client, "id": id]
        if requireLocalOutput { command["local_output"] = "required" }
        let data = try JSONSerialization.data(withJSONObject: command) + Data([10])
        cache.beginPause(at: requestedAt)
        return try await PlaybackDeadline.run(seconds: PlaybackPauseBudget.reply, sleep: sleep, now: now, onAbort: {
            // Retire the transport before ownership can be released. A command may
            // have reached the child even if its reply or write acknowledgement did not.
            invalidate()
            self.failAll()
        }) {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.controls[id] = Pending(client: client, requestedAt: requestedAt, continuation: continuation)
                do { try write(data) }
                catch {
                    invalidate()
                    self.failAll()
                }
            }
        }
    }
    func failAll() {
        let pending = controls.values
        controls.removeAll()
        cache = PlaybackObservationCache()
        for control in pending {
            control.continuation.resume(throwing: PlaybackControlError(message: "Mac playback observer stopped before pause confirmation"))
        }
    }
    func consume(_ row: [String: Any]) {
        let now = now()
        if let id = row["control"] as? String {
            guard let control = controls.removeValue(forKey: id) else { return }
            guard let paused = row["paused"] as? Bool,
                  let observation = Self.observation(from: row),
                  cache.acceptPauseReply(ok: row["ok"] as? Bool == true, paused: paused, observation: observation,
                                         client: control.client, requestedAt: control.requestedAt, now: now) else {
                control.continuation.resume(throwing: PlaybackControlError(message: "Mac pause failed or has no fresh verified player observation"))
                return
            }
            onVerifiedPause?(observation, cachedReading())
            control.continuation.resume(returning: (paused, observation))
        } else if let observation = Self.observation(from: row), observation.revision != nil {
            cache.observe(observation, at: now)
        }
    }
    private static func observation(from row: [String: Any]) -> PlaybackObservation? {
        guard let playing = row["playing"] as? Bool, let client = row["client"] as? String,
              let uptime = row["uptime"] as? Double else { return nil }
        return PlaybackObservation(playing: playing, client: client, uptime: uptime,
                                   revision: (row["revision"] as? NSNumber)?.uint64Value)
    }
}

/// Local development fallback: a persistent Apple Swift interpreter reads the same
/// native getters and explicit pause. No audio capture, remote service or permission changes.
@MainActor private final class InterpretedPlaybackReader {
    private let channel = PlaybackPauseControlChannel()
    private let pauses = PlaybackPauseCoordinator<PlaybackPauseResult>()
    var onVerifiedPause: ((PlaybackObservation, PlaybackReading?) -> Void)? {
        get { channel.onVerifiedPause }
        set { channel.onVerifiedPause = newValue }
    }
    private var process: Process?
    private var processID: UUID?
    private var pipe: Pipe?
    private var input: Pipe?
    private var buffer = Data()
    private var nextLaunch: TimeInterval = 0
    deinit {
        pipe?.fileHandleForReading.readabilityHandler = nil
        if process?.isRunning == true { process?.terminate() }
    }
    func read() async -> PlaybackReading {
        startIfNeeded()
        for _ in 0..<20 {
            guard !Task.isCancelled else { return .unknown }
            if let latest = cachedReading() { return latest }
            guard process?.isRunning == true else { return .unknown }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return .unknown
    }
    func cachedReading() -> PlaybackReading? { channel.cachedReading() }
    func pauseObservation(client: String, requireLocalOutput: Bool = false) async throws -> PlaybackPauseResult {
        try await pauses.perform(client: client) {
            let current = await self.read()
            try Task.checkCancellation()
            guard current.client == client, current.playing != nil else {
                throw PlaybackControlError(message: "Mac player is unavailable for pause")
            }
            guard self.process?.isRunning == true, let input = self.input else {
                throw PlaybackControlError(message: "Mac playback observer is unavailable")
            }
            return try await self.channel.request(client: client, requireLocalOutput: requireLocalOutput, write: {
                try input.fileHandleForWriting.write(contentsOf: $0)
            }, invalidate: { self.invalidate() })
        }
    }
    func invalidate() {
        // Epoch fence drops queued stdout and termination callbacks from this child.
        processID = nil
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? input?.fileHandleForWriting.close()
        process = nil
        pipe = nil
        input = nil
        buffer.removeAll()
        channel.failAll()
    }
    private func startIfNeeded() {
        guard process?.isRunning != true, ProcessInfo.processInfo.systemUptime >= nextLaunch else { return }
        invalidate()
        nextLaunch = ProcessInfo.processInfo.systemUptime + 30
        guard let source = Bundle.main.resourceURL?.appendingPathComponent("PlaybackObserver.swift"),
              FileManager.default.fileExists(atPath: source.path) else { return }
        let task = Process(), output = Pipe(), commands = Pipe(), epoch = UUID()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        task.arguments = [source.path]
        var environment = ProcessInfo.processInfo.environment
        environment["BUDS_PLAYBACK_OBSERVER"] = "1"
        environment["BUDS_PLAYBACK_OWNER_PID"] = String(getpid())
        task.environment = environment
        task.standardInput = commands
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor [weak self] in
                guard let self, self.processID == epoch else { return }
                if data.isEmpty { self.invalidate() }
                else { self.consume(data) }
            }
        }
        task.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.processID == epoch else { return }
                self.invalidate()
            }
        }
        do {
            try task.run()
            process = task; processID = epoch; pipe = output; input = commands
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            task.terminationHandler = nil
            channel.failAll()
        }
    }
    private func consume(_ data: Data) {
        buffer.append(data)
        guard buffer.count <= 65536 else { invalidate(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            channel.consume(row)
        }
    }
}


/// The installed MediaRemote provider omits PlaybackRate for a paused player.
/// Fresh callbacks identifying a client and nonnil info still prove an explicit
/// false. A missing rate never authorizes a playing edge.
enum PlaybackNativeEvidence {
    static func reading(playing: Bool?, rate: Double?, hasInfo: Bool, client: String?,
                        observedAt: TimeInterval, timedOut: Bool) -> PlaybackReading {
        guard !timedOut, observedAt.isFinite, let playing, let client, !client.isEmpty else {
            return PlaybackReading(observedAt: observedAt)
        }
        if let rate {
            guard rate.isFinite, rate >= 0, playing == (rate > 0) else {
                return PlaybackReading(observedAt: observedAt)
            }
        } else if !hasInfo || playing {
            return PlaybackReading(observedAt: observedAt)
        }
        return PlaybackReading(playing: playing, client: client, observedAt: observedAt)
    }
}
