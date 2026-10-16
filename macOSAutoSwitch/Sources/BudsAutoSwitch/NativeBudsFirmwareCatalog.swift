import Foundation

/// The original client's public catalogue, queried only by an explicit action.
/// Listing a build is independent of permission to transfer it to a device.
@MainActor final class NativeBudsFirmwareCatalog {
    struct Entry: Decodable, Equatable {
        let model: String
        let buildName: String
        let region: String?
        let bootloaderVersion: String?
    }
    typealias Loader = @Sendable (URL) async throws -> Data
    private let load: Loader
    private var address = ""
    private var model: NativeBudsFirmware.Model?
    private var installed: String?
    private var entries: [Entry] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var checkedAt: Date?
    private var error = ""
    private(set) var busy = false

    init(load: @escaping Loader = NativeBudsFirmwareCatalog.downloadCatalogue) { self.load = load }
    deinit { task?.cancel() }

    func select(address: String, model: String?, installed: String?) {
        let next = model.flatMap(NativeBudsFirmware.Model.init(rawValue:))
        if self.address != address || self.model != next {
            task?.cancel(); task = nil; generation = UUID(); entries = []; checkedAt = nil; error = ""; busy = false
        }
        self.address = address; self.model = next
        self.installed = next.flatMap { Self.validVersion(installed, model: $0) }
    }

    func refresh() {
        guard let model, !address.isEmpty, !busy,
              let url = URL(string: "https://fw.timschneeberger.me/v3/firmware/" + model.rawValue) else { return }
        let token = generation
        let load = load
        busy = true; error = ""
        task = Task { @MainActor [weak self] in
            do {
                let data = try await load(url)
                try Task.checkCancellation()
                let result = try Self.parse(data, model: model)
                guard let self, self.generation == token else { return }
                self.entries = result; self.checkedAt = Date(); self.busy = false; self.task = nil
            } catch is CancellationError { }
            catch {
                guard let self, self.generation == token else { return }
                self.busy = false; self.task = nil
                self.error = "Não foi possível consultar o firmware. Verifique a internet e tente novamente."
            }
        }
    }

    var snapshot: [String: Any] {
        let comparisons = entries.compactMap { Self.newer($0.buildName, than: installed) }
        let hasUpdate: Bool? = checkedAt != nil && !comparisons.isEmpty ? comparisons.contains(true) : nil
        return [
            "available": model != nil && !address.isEmpty, "busy": busy,
            "installed_version": installed as Any? ?? NSNull(),
            "checked_at": checkedAt?.timeIntervalSince1970 as Any? ?? NSNull(),
            "has_update": hasUpdate as Any? ?? NSNull(),
            "versions": entries.map { entry -> [String: Any] in
                ["build": entry.buildName, "region": entry.region as Any? ?? NSNull(),
                 "is_newer": Self.newer(entry.buildName, than: installed) as Any? ?? NSNull()]
            }, "error": error
        ]
    }

    static func validVersion(_ value: String?, model: NativeBudsFirmware.Model) -> String? {
        guard let value, value.utf8.count == 12, value.hasPrefix(model.identifier),
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }) else { return nil }
        return value
    }

    static func newer(_ candidate: String, than current: String?) -> Bool? {
        guard let current, current.utf8.count == 12, candidate.utf8.count == 12,
              candidate.prefix(9) == current.prefix(9) else { return nil }
        return candidate.suffix(3).lexicographicallyPrecedes(current.suffix(3)) ? false : candidate.suffix(3) != current.suffix(3)
    }

    static func parse(_ data: Data, model: NativeBudsFirmware.Model) throws -> [Entry] {
        guard data.count <= 1_048_576 else { throw URLError(.dataLengthExceedsMaximum) }
        let decoded = try JSONDecoder().decode([Entry].self, from: data)
        guard decoded.count <= 1000 else { throw URLError(.dataLengthExceedsMaximum) }
        let selected = decoded.filter { $0.model == model.rawValue && validVersion($0.buildName, model: model) != nil }
        return Array(Dictionary(grouping: selected, by: \.buildName).compactMap { $0.value.first })
            .sorted { $0.buildName > $1.buildName }
    }

    nonisolated static func downloadCatalogue(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == "fw.timschneeberger.me",
              data.count <= 1_048_576 else { throw URLError(.badServerResponse) }
        return data
    }
}
