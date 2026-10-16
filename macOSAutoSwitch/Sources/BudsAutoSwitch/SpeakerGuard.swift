import Foundation
import CoreAudio
import Darwin

/// Hardware mute only. Call arm before playback and restore only after route confirmation.
@MainActor final class SpeakerGuard {
    private let state: SpeakerGuardState
    var isArmed: Bool { state.record != nil }
    var armedDevice: UInt32? { state.device }

    init() { state = SpeakerGuardState(environment: .live()) }
    init(environment: SpeakerGuardEnvironment) { state = SpeakerGuardState(environment: environment) }

    func arm(_ device: UInt32) async throws { try state.arm(device) }
    func restore() async throws { try state.restore() }
    func verify() throws { try state.verify() }

    static func recoverAbandoned() async throws {
        try SpeakerGuardState.recoverAbandoned(environment: .live())
    }

    /// Runs before SwiftUI creates any windows. This worker deliberately blocks.
    nonisolated static func runWatchdogIfRequested() {
        let args = CommandLine.arguments
        guard args.contains(SpeakerGuardEnvironment.watchdogFlag) else { return }
        func argument(_ name: String) -> String? {
            guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        guard let token = argument("--token"), UUID(uuidString: token) != nil,
              let owner = argument("--owner-pid").flatMap(Int32.init), owner > 0 else {
            fputs("SpeakerGuard: invalid watchdog arguments\n", stderr)
            exit(1)
        }
        let environment = SpeakerGuardEnvironment.live()
        do {
            while try SpeakerGuardState.watchdogTick(environment: environment, token: token, owner: owner) {
                Thread.sleep(forTimeInterval: 0.250)
            }
            exit(0)
        } catch {
            // Leave the journal available for the next startup; do not hide a failed recovery.
            fputs("SpeakerGuard: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

struct SpeakerGuardRecord: Codable, Equatable {
    let deviceUID: String
    let originalMute: UInt32
    let ownerPID: Int32
    let token: String
    var manuallyUnmuted = false

    func owned(by other: SpeakerGuardRecord) -> Bool {
        ownerPID == other.ownerPID && token == other.token
    }
}

protocol SpeakerGuardJournal {
    func withLock(_ action: () throws -> Void) throws
    func read() throws -> SpeakerGuardRecord?
    func write(_ record: SpeakerGuardRecord) throws
    func remove() throws
}

struct SpeakerGuardEnvironment {
    static let watchdogFlag = "--buds-speaker-guard-watchdog"
    let journal: SpeakerGuardJournal
    let pid: Int32
    let isAlive: (Int32) -> Bool
    let uid: (UInt32) throws -> String
    let resolve: (String) throws -> UInt32
    /// Reads output master mute and checks that it is settable.
    let mute: (UInt32) throws -> UInt32
    /// Must confirm the write within a bounded deadline, or throw.
    let setMute: (UInt32, UInt32) throws -> Void
    let startWatchdog: (SpeakerGuardRecord) throws -> Void

    static func live() -> Self {
        Self(journal: SpeakerGuardFileJournal(), pid: getpid(),
             isAlive: { kill($0, 0) == 0 || errno != ESRCH },
             uid: { device in
                 guard let uid = MacAudio.string(device, kAudioDevicePropertyDeviceUID), !uid.isEmpty else {
                     throw guardError("Não foi possível identificar a saída de áudio.", "Cannot identify the audio output.")
                 }
                 return uid
             }, resolve: { uid in
                 guard let device = try MacAudio.ids(MacAudio.system, kAudioHardwarePropertyDevices).first(where: {
                     MacAudio.string($0, kAudioDevicePropertyDeviceUID) == uid
                 }) else {
                     throw guardError("Saída de áudio indisponível; a recuperação do mute continua pendente.",
                                      "Audio output unavailable; mute recovery remains pending.")
                 }
                 return device
             }, mute: readHardwareMute, setMute: writeHardwareMute,
             startWatchdog: { record in
#if BUDS_EMBEDDED
                 let worker = Bundle.main.url(forAuxiliaryExecutable: "BudsGuardHelper")
#else
                 let worker = Bundle.main.executableURL
#endif
                 guard let executable = worker else {
                     throw guardError("Executável do watchdog indisponível.", "Watchdog executable unavailable.")
                 }
                 let process = Process()
                 process.executableURL = executable
                 process.arguments = [watchdogFlag, "--token", record.token, "--owner-pid", String(record.ownerPID)]
                 process.standardInput = FileHandle.nullDevice
                 process.standardOutput = FileHandle.nullDevice
                 // stderr remains visible for explicit recovery errors.
                 try process.run()
             })
    }
}

private func guardError(_ pt: String, _ en: String) -> BridgeError { .message(L(pt, en)) }

private func readHardwareMute(_ device: UInt32) throws -> UInt32 {
    var address = MacAudio.property(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    var settable = DarwinBoolean(false)
    guard AudioObjectHasProperty(device, &address),
          AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else {
        throw guardError("Esta saída não oferece mute de hardware na saída principal. A proteção não foi ativada.",
                         "This output has no settable master hardware mute. Protection was not enabled.")
    }
    var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
    let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
    guard status == noErr, size == MemoryLayout<UInt32>.size, value <= 1 else {
        throw guardError("Não foi possível ler o mute da saída (CoreAudio: \(status)).",
                         "Cannot read output mute (CoreAudio: \(status)).")
    }
    return value
}

private func writeHardwareMute(_ device: UInt32, _ mute: UInt32) throws {
    _ = try readHardwareMute(device)
    var address = MacAudio.property(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
    var value = mute
    let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    guard status == noErr else {
        throw guardError("Falha ao alterar mute (CoreAudio: \(status)); recuperação pendente.",
                         "Mute write failed (CoreAudio: \(status)); recovery pending.")
    }
    // No suspension while holding the cross-process lock. At most one second.
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    repeat {
        if try readHardwareMute(device) == mute { return }
        Thread.sleep(forTimeInterval: 0.020)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw guardError("O mute não foi confirmado em um segundo; recuperação pendente.",
                     "Mute was not confirmed within one second; recovery pending.")
}

/// Synchronous transactions prevent actor reentrancy and watchdog/startup races.
final class SpeakerGuardState {
    private let environment: SpeakerGuardEnvironment
    private(set) var record: SpeakerGuardRecord?
    private(set) var device: UInt32?

    init(environment: SpeakerGuardEnvironment) { self.environment = environment }

    func arm(_ device: UInt32) throws {
        if record != nil {
            guard self.device == device else {
                throw guardError("Restaure a proteção anterior antes de proteger outra saída.",
                                 "Restore the previous guard before protecting another output.")
            }
            try verify()
            return
        }
        try environment.journal.withLock {
            if let previous = try environment.journal.read() {
                guard !environment.isAlive(previous.ownerPID) else {
                    throw guardError("Outra instância já protege a saída de áudio.", "Another instance already guards the audio output.")
                }
                try Self.recover(previous, environment: environment)
            }
            let original = try environment.mute(device)
            guard original <= 1 else { throw guardError("Mute inválido.", "Invalid mute value.") }
            let entry = SpeakerGuardRecord(deviceUID: try environment.uid(device), originalMute: original,
                                           ownerPID: environment.pid, token: UUID().uuidString)
            try environment.journal.write(entry)
            record = entry
            self.device = device
            do { try environment.startWatchdog(entry) }
            catch {
                let launchError = error
                do {
                    try environment.journal.remove()
                    record = nil
                    self.device = nil
                } catch {
                    throw guardError("Watchdog: \(launchError.localizedDescription). Falha ao limpar recuperação: \(error.localizedDescription)",
                                     "Watchdog: \(launchError.localizedDescription). Recovery cleanup failed: \(error.localizedDescription)")
                }
                throw guardError("Não foi possível iniciar o watchdog: \(launchError.localizedDescription)",
                                 "Cannot start watchdog: \(launchError.localizedDescription)")
            }
            // Any write/confirmation failure keeps both ownership and recovery information.
            if original == 0 { try environment.setMute(device, 1) }
        }
    }

    func verify() throws {
        guard var entry = record else { return }
        try environment.journal.withLock {
            try requireOwnership(entry)
            let currentDevice = try environment.resolve(entry.deviceUID)
            // CoreAudio can re-enumerate a device without changing its UID.
            // Route guards must compare against its current object ID.
            device = currentDevice
            if try environment.mute(currentDevice) == 0 {
                entry.manuallyUnmuted = true
                record = entry
                try environment.journal.write(entry)
            }
            guard !entry.manuallyUnmuted else {
                throw guardError("Foi observado um desmute da saída. A proteção foi interrompida; o estado atual será respeitado.",
                                 "An output unmute was observed. Protection was interrupted; the current state will be respected.")
            }
        }
    }

    func restore() throws {
        guard let entry = record else { return }
        try environment.journal.withLock {
            try requireOwnership(entry)
            try Self.recover(entry, environment: environment)
            record = nil
            device = nil
        }
    }

    private func requireOwnership(_ entry: SpeakerGuardRecord) throws {
        guard let stored = try environment.journal.read(), stored.owned(by: entry) else {
            throw guardError("O journal de proteção mudou; a restauração foi interrompida para preservar seu proprietário.",
                             "Guard journal ownership changed; restoration stopped to preserve its owner.")
        }
    }

    private static func recover(_ entry: SpeakerGuardRecord, environment: SpeakerGuardEnvironment) throws {
        let device = try environment.resolve(entry.deviceUID)
        let mute = try environment.mute(device)
        // Never counter a manual unmute, including when the original state was muted.
        if mute == 1 && !entry.manuallyUnmuted && entry.originalMute != mute {
            try environment.setMute(device, entry.originalMute)
        }
        try environment.journal.remove()
    }

    static func recoverAbandoned(environment: SpeakerGuardEnvironment) throws {
        try environment.journal.withLock {
            guard let entry = try environment.journal.read(), !environment.isAlive(entry.ownerPID) else { return }
            try recover(entry, environment: environment)
        }
    }

    /// Returns false when ownership ended or recovery completed.
    static func watchdogTick(environment: SpeakerGuardEnvironment, token: String, owner: Int32) throws -> Bool {
        var keepWatching = false
        try environment.journal.withLock {
            guard let entry = try environment.journal.read(), entry.token == token, entry.ownerPID == owner else { return }
            if environment.isAlive(owner) { keepWatching = true }
            else { try recover(entry, environment: environment) }
        }
        return keepWatching
    }
}

/// All read/write/remove operations are performed under an exclusive flock.
final class SpeakerGuardFileJournal: SpeakerGuardJournal {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("recovery.json") }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BudsAutoSwitch/SpeakerGuard", isDirectory: true)) {
        self.directory = directory
    }

    func withLock(_ action: () throws -> Void) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw ioError("directory") }
        defer { close(directoryFD) }
        var info = stat()
        guard fstat(directoryFD, &info) == 0, info.st_uid == getuid(), fchmod(directoryFD, 0o700) == 0 else {
            throw ioError("directory permissions")
        }
        let fd = open(directory.appendingPathComponent("recovery.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ioError("lock") }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              fchmod(fd, 0o600) == 0, flock(fd, LOCK_EX) == 0 else { throw ioError("lock acquisition") }
        defer { flock(fd, LOCK_UN) }
        try action()
    }

    func read() throws -> SpeakerGuardRecord? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw ioError("read") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_size <= 4096 else { throw ioError("journal permissions/size") }
        let entry = try JSONDecoder().decode(SpeakerGuardRecord.self, from: handle.readToEnd() ?? Data())
        guard !entry.deviceUID.isEmpty, entry.originalMute <= 1, entry.ownerPID > 0, UUID(uuidString: entry.token) != nil else {
            throw guardError("Journal de recuperação inválido; não foi alterado.", "Invalid recovery journal; left unchanged.")
        }
        return entry
    }

    func write(_ record: SpeakerGuardRecord) throws {
        // mkstemp creates mode 0600 before any recovery information is written.
        var template = Array(directory.appendingPathComponent(".recovery-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw ioError("temporary journal") }
        let temporary = String(cString: template)
        defer { unlink(temporary) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: JSONEncoder().encode(record))
        guard fsync(fd) == 0, rename(temporary, file.path) == 0 else { throw ioError("persist journal") }
    }

    func remove() throws {
        guard unlink(file.path) == 0 || errno == ENOENT else { throw ioError("remove journal") }
    }

    private func ioError(_ operation: String) -> BridgeError {
        guardError("Falha no journal de recuperação (\(operation)): \(String(cString: strerror(errno))). Recuperação pendente.",
                   "Recovery journal failed (\(operation)): \(String(cString: strerror(errno))). Recovery pending.")
    }
}
