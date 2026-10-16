#if BUDS_EMBEDDED
import AppKit
import SwiftUI
import Combine

private typealias PanelAction = @convention(c) (UnsafePointer<CChar>?) -> Void

/// Presentation only. Commands return to the managed host, which owns the
/// existing SMEP reservation and cancellation generation.
@MainActor private final class BudsPanelModel: ObservableObject {
    @Published var root: [String: Any] = [:]
    @Published var accountOpen = false
    @Published var settingsOpen = false
    @Published var actionError: String?
    @Published var readFailed = false
    @Published var avatar: NSImage?
    @Published var feature: String?
    @Published var requestedNoise: String?
    private var requestedNoiseAt: Date?
    private var observedNoiseBusy = false
    @Published var findTarget = "both"
    @Published var controlsExpanded = true
    @Published var toolsExpanded = false
    @Published var updatesExpanded = false
    private var avatarRevision: Int32 = -1
    private var timer: Timer?
    private let callback: PanelAction
    #if BUDS_PANEL_PREVIEW
    var previewResources: URL?
    var previewScrollTarget: String?
    #endif
    var resourceDirectory: URL? {
        #if BUDS_PANEL_PREVIEW
        return previewResources
        #else
        return Bundle.main.resourceURL
        #endif
    }
    #if DEBUG
    private var reviewFixture: [String: Any]?
    func installReviewFixture(buds4: Bool = false) {
        var fixture = root
        var switching = self.switching
        switching.merge(["device_name": "Teste visual · Buds3 Pro", "enabled": true, "starting": false,
            "busy": false, "settling": false, "native_channel_open": true, "route": "Mac", "error": "",
            "battery": ["left": 85, "right": 82, "case": 60, "observed_at": ISO8601DateFormatter().string(from: Date())]]) { _, new in new }
        fixture["switching"] = switching
        fixture["device_metadata"] = ["model": "Buds3Pro", "icon_prefix": "Buds3ProSilver", "bluetooth_connected": true]
        fixture["device"] = ["available": true, "busy": false, "connected": true, "can_control": true,
            "model_verified": true, "read_fresh": true, "observed_at": Date().timeIntervalSince1970,
            "can_refresh": true, "can_touch": true, "noise_mode": "anc", "equalizer": 0, "ambient_level": 2,
            "touch_enabled": true, "media_controls_enabled": true, "media_controls_mixed": false,
            "touch_controls": ["single_pinch": true, "double_pinch": true, "triple_pinch": true,
                "swipe": true, "call_double_pinch": true, "call_hold": true],
            "status": "Cenário de teste visual. Nenhum comando é enviado ao fone."] as [String: Any]
        fixture["volume"] = ["available": true, "can_set": true, "level": 35]
        if buds4 {
            switching["device_name"] = "Teste visual · Buds4"
            fixture["switching"] = switching
            var metadata = NativeBudsProfile.resolve(model: "Buds4", name: "").fields
            metadata["icon_prefix"] = "Buds4White"; metadata["bluetooth_connected"] = true
            fixture["device_metadata"] = metadata
            fixture["device"] = ["available": true, "busy": false, "connected": true,
                "can_control": false, "can_refresh": false, "can_touch": false,
                "status": "Os ajustes específicos deste modelo ainda estão em validação."] as [String: Any]
        }
        reviewFixture = fixture; root = fixture
    }
    func clearReviewFixture() { reviewFixture = nil }
    #endif
    init(callback: @escaping PanelAction) { self.callback = callback }
    var account: [String: Any] { root["account"] as? [String: Any] ?? [:] }
    var switching: [String: Any] { root["switching"] as? [String: Any] ?? [:] }
    var device: [String: Any] { root["device"] as? [String: Any] ?? [:] }
    var volume: [String: Any] { root["volume"] as? [String: Any] ?? [:] }
    var metadata: [String: Any] { root["device_metadata"] as? [String: Any] ?? [:] }
    var hasCurrentDeviceState: Bool {
        flag(device, "can_control") || flag(volume, "can_set")
            || (text(switching, "route") == "Mac" && flag(switching, "native_channel_open"))
    }
    var connected: Bool {
        NativeBudsPanelConnection.connected(readFailed: readFailed,
            physicalLink: boolean(metadata, "bluetooth_connected"),
            audioPresent: boolean(metadata, "audio_endpoint_present"),
            deviceState: hasCurrentDeviceState,
            existingSettingsRoute: flag(metadata, "existing_mac_settings_route"))
    }
    var unavailable: String { connected ? "Indisponível" : "Sem conexão" }
    var active: Bool { flag(switching, "enabled") || flag(switching, "starting") }
    var canChoose: Bool { !readFailed && boolean(switching, "enabled") == false && boolean(switching, "starting") == false && boolean(switching, "busy") == false && boolean(switching, "settling") == false && boolean(switching, "recovery_pending") == false }
    var canToggle: Bool { active || (canChoose && flag(switching, "ready")) }
    var canRefresh: Bool { !readFailed && (connected || boolean(metadata, "bluetooth_connected") == true) && flag(device, "available") && boolean(device, "busy") == false && (boolean(device, "can_refresh") ?? flag(device, "can_control")) }
    var canControl: Bool { canRefresh && connected && flag(device, "can_control") }
    var displayedSettings: NativeBudsPanelReadings.Settings? {
        NativeBudsPanelReadings.settings(device, connected: connected, canControl: canControl)
    }
    var displaySettings: [String: Any] { displayedSettings?.values ?? [:] }
    var error: String? {
        if let actionError { return actionError }
        if readFailed { return "Não foi possível atualizar o painel. Tentando novamente…" }
        return [text(switching, "error"), text(device, "error"), text(volume, "error")].first { !$0.isEmpty }
    }
    func start() {
        guard timer == nil else { return }
        refresh()
        let next = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
    func stop() { timer?.invalidate(); timer = nil }
    func refresh() {
        #if BUDS_PANEL_PREVIEW
        return // Standalone previews have no host, account or device reader.
        #else
        #if DEBUG
        if let fixture = reviewFixture { root = fixture; return }
        #endif
        guard let pointer = budsCopyState(avatarRevision) else { readFailed = true; return }
        defer { budsFreeState(pointer) }
        guard let data = String(cString: pointer).data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              value["switching"] is [String: Any], value["device"] is [String: Any],
              value["account"] is [String: Any] else { readFailed = true; return }
        let priorIdentity = flag(account, "needs_identity")
        root = value; readFailed = false
        if requestedNoise != nil {
            observedNoiseBusy = observedNoiseBusy || flag(device, "busy")
            if !connected || !text(device, "error").isEmpty || (!flag(device, "busy") &&
                (observedNoiseBusy || text(device, "noise_mode") == requestedNoise ||
                 requestedNoiseAt.map { Date().timeIntervalSince($0) > 30 } == true)) {
                requestedNoise = nil; requestedNoiseAt = nil; observedNoiseBusy = false
            }
        }
        if account.keys.contains("avatar") {
            avatar = (account["avatar"] as? String).flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            let revision = number(account, "avatar_revision") ?? -1
            avatarRevision = revision >= -1 && revision <= Double(Int32.max) ? Int32(revision) : -1
        }
        if flag(account, "needs_identity") || flag(account, "can_cancel") { accountOpen = true }
        if priorIdentity && !flag(account, "needs_identity") { identity = "" }
        if flag(switching, "recovery_pending") { settingsOpen = true }
        if let tools = device["tools"] as? [String: Any], flag(tools, "active") { toolsExpanded = true; settingsOpen = true }
        let updating = root["app_update"] as? [String: Any] ?? [:]
        if ["waiting_for_safe_install", "preparing_shutdown", "installing"].contains(text(updating, "status")) {
            settingsOpen = true; updatesExpanded = true
        }
        #endif
    }
    @Published var identity = ""
    func send(_ action: String, _ values: [String: Any] = [:]) {
        #if BUDS_PANEL_PREVIEW
        return // Compile-time command isolation, including sliders and refresh.
        #else
        #if DEBUG
        if reviewFixture != nil { return } // Visual fixture cannot issue real commands.
        #endif
        var request = values; request["action"] = action
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let json = String(data: data, encoding: .utf8) else { return }
        actionError = nil
        if action == "device.noise", let mode = values["mode"] as? String {
            requestedNoise = mode; requestedNoiseAt = Date(); observedNoiseBusy = false
        }
        json.withCString { callback($0) }
        #endif
    }

}

private func text(_ object: [String: Any], _ key: String, _ fallback: String = "") -> String {
    guard let value = object[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
    return value
}
private func boolean(_ object: [String: Any], _ key: String) -> Bool? {
    guard let n = object[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
    return n.boolValue
}
private func flag(_ object: [String: Any], _ key: String) -> Bool { boolean(object, key) == true }
private func number(_ object: [String: Any], _ key: String) -> Double? {
    guard let n = object[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
    return n.doubleValue
}
private let noiseOptions = [("off", "Desligado"), ("anc", "Cancelamento"), ("ambient", "Som ambiente"), ("adaptive", "Adaptável")]
private let eqOptions = ["Normal", "Graves", "Suave", "Dinâmico", "Nítido", "Agudos"]

@MainActor private struct BudsPanel: View {
    @ObservedObject var model: BudsPanelModel
    @FocusState private var identityFocused: Bool
    @FocusState private var accountFocused: Bool
    @State private var balanceDraft = 16.0
    @State private var balanceEditing = false
    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                artwork
                battery
                features
                footer
                if let error = model.error { errorView(error).id("panel-error") }
                if model.settingsOpen { settings.id("switch-details") }
                if model.accountOpen { account.id("account-details") }
            }
            .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .scrollContentBackground(.hidden)
        .font(.system(size: 13))
        .modifier(NativeBudsActionStyle())
        .controlSize(.regular)
        .tint(.primary)
        .preferredColorScheme(.dark)
        .environment(\.controlActiveState, .active)
        #if BUDS_PANEL_PREVIEW
        .onAppear {
            if let target = model.previewScrollTarget {
                DispatchQueue.main.async { scroll.scrollTo(target, anchor: .top) }
            }
        }
        #endif
        .onChange(of: flag(model.account, "needs_identity")) { _, needs in identityFocused = needs }
        .onChange(of: model.settingsOpen) { _, open in if open { scroll.scrollTo("switch-details", anchor: .top) } }
        .onChange(of: model.accountOpen) { _, open in if open { scroll.scrollTo("account-details", anchor: .top) } }
        .onChange(of: model.actionError) { _, error in if error != nil { scroll.scrollTo("panel-error", anchor: .bottom) } }
        }
    }
    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(text(model.switching, "device_name", "Galaxy Buds")).font(.system(size: 20, weight: .semibold)).lineLimit(2)
                Text(connection).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }
    private var connection: String {
        if model.readFailed { return "Desconectados" }
        if model.connected { return "Conectados ao Mac" }
        return flag(model.switching, "busy") ? "Conectando…" : "Desconectados"
    }
    private var artwork: some View {
        HStack(spacing: 0) {
            budImage(0).accessibilityHidden(true)
            budImage(1).accessibilityHidden(true)
        }
        .frame(height: 124).frame(maxWidth: .infinity)
        .opacity(model.connected ? 1 : 0.45)
        .accessibilityElement(children: .ignore).accessibilityLabel(text(model.metadata, "model", "Fones Galaxy Buds"))
    }
    private func budImage(_ side: Int) -> some View {
        let prefix = text(model.metadata, "icon_prefix")
        let validPrefix = prefix.range(of: "^[A-Za-z][A-Za-z0-9]{1,63}\\z", options: .regularExpression) != nil
        return Group {
            if validPrefix, let directory = model.resourceDirectory,
               let image = NSImage(contentsOf: directory.appendingPathComponent("BudsImages/\(prefix)-\(side).png")) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else { Image(systemName: side == 0 ? "earbud.left" : "earbud.right").resizable().scaledToFit().padding(30).foregroundStyle(.secondary) }
        }.frame(width: 142, height: 124)
    }
    private var battery: some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                batteryItem("Esquerdo", key: "left", symbol: "earbud.left")
                batteryItem("Direito", key: "right", symbol: "earbud.right")
                batteryItem("Estojo", key: "case", symbol: "earbuds.case")
            }
            Text(batteryObservation).font(.system(size: 11)).foregroundStyle(.secondary)
                .help("Percentuais da última leitura. Um traço indica bateria sem leitura.")
        }
    }
    private func batteryItem(_ name: String, key: String, symbol: String) -> some View {
        let battery = model.switching["battery"] as? [String: Any] ?? [:]
        let value = NativeBudsPanelReadings.battery(battery, key: key, connected: model.connected)
        return VStack(spacing: 5) {
            Text(value.map { "\($0)%" } ?? "—").font(.system(size: key == "case" ? 23 : 30, weight: .medium, design: .rounded)).monospacedDigit()
            Label(name, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(name): \(value.map { "\($0) por cento" } ?? (model.connected ? "bateria indisponível" : "desconectado"))")
    }
    private var batteryObservation: String {
        if !model.connected { return "Conecte os Buds para ver a bateria" }
        let battery = model.switching["battery"] as? [String: Any] ?? [:]
        guard ["left", "right", "case"].contains(where: { NativeBudsPanelReadings.battery(battery, key: $0, connected: true) != nil }) else {
            return model.canRefresh ? "Atualize para ler a bateria" : "Bateria indisponível"
        }
        let date: Date?
        if let seconds = number(battery, "observed_at") { date = abs(seconds) < 253402300799 ? Date(timeIntervalSince1970: seconds) : nil }
        else { date = ISO8601DateFormatter().date(from: text(battery, "observed_at")) }
        guard let date else { return "Horário da leitura indisponível" }
        let formatter = DateFormatter(); formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short; formatter.timeStyle = .short
        return "\(Date().timeIntervalSince(date) > 300 ? "Última leitura" : "Bateria lida em") · \(formatter.string(from: date))"
    }
    private var switching: some View {
        HStack {
            Label(flag(model.switching, "starting") ? "Preparando conexão…" : "Alternância automática", systemImage: "arrow.triangle.swap")
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Toggle("Alternância automática", isOn: Binding(get: { model.active }, set: { model.send($0 ? "switch.start" : "switch.stop") }))
                .labelsHidden().toggleStyle(.switch).controlSize(.regular).disabled(!model.canToggle)
        }
    }
    private var features: some View {
        VStack(alignment: .leading, spacing: 5) {
        noiseControl
        HStack(spacing: 8) {
            featureButton("equalizer", title: "Equalizador", value: eqValue, symbol: "slider.horizontal.3")
            featureButton("levels", title: "Intensidade", value: levelSummary, symbol: "slider.horizontal.3")
            featureButton("touch", title: "Gestos", value: flag(model.displaySettings, "media_controls_mixed") ? "Personalizados" : boolean(model.displaySettings, "media_controls_enabled").map { $0 ? "Ativados" : "Desativados" } ?? model.unavailable, symbol: "hand.tap")
        }
        .disabled(!model.canControl).opacity(model.canControl ? 1 : 0.55)
        }
    }
    private var noiseControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Controle de ruído").font(.system(size: 11, weight: .medium))
            Picker("Controle de ruído", selection: Binding(
                get: { model.requestedNoise ?? text(model.displaySettings, "noise_mode") },
                set: { if $0 != text(model.displaySettings, "noise_mode") { model.send("device.noise", ["mode": $0]) } })) {
                ForEach(availableNoiseOptions, id: \.0) { option in
                    Text(option.0 == "anc" ? "ANC" : option.0 == "ambient" ? "Ambiente" : option.1).tag(option.0)
                }
            }.pickerStyle(.segmented).labelsHidden()
                .disabled(!model.canControl || model.requestedNoise != nil)
        }.padding(.bottom, 8)
    }
    private func featureButton(_ key: String, title: String, value: String, symbol: String) -> some View {
        Button {
            model.feature = key
            if model.canRefresh && (!model.canControl || (key == "touch" && !canTouch)) { model.send("device.refresh") }
        } label: { tile(title, value: value, symbol: symbol) }
            .buttonStyle(.plain).frame(maxWidth: .infinity)
            .accessibilityLabel("\(title): \(value). Mostrar opções")
            .popover(isPresented: Binding(get: { model.feature == key }, set: { if !$0 { model.feature = nil } }), arrowEdge: .top) {
                featureOptions(key, title: title)
            }
    }
    private var levelSummary: String {
        let kind = text(model.displaySettings, "noise_mode") == "ambient" ? "ambient" : "anc"
        guard let levels = model.displaySettings["levels"] as? [String: Any],
              let level = levels[kind] as? [String: Any], let value = number(level, "value") else { return model.unavailable }
        if number(level, "maximum") == 1 { return value == 0 ? "Baixa" : "Alta" }
        return "Nível \(Int(value) + 1)"
    }
    private var availableNoiseOptions: [(String, String)] {
        guard let modes = model.device["noise_modes"] as? [String] else { return noiseOptions }
        return noiseOptions.filter { modes.contains($0.0) }
    }
    fileprivate func featureOptions(_ key: String, title: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            if key == "noise" {
                Picker("Modo de ruído", selection: Binding(get: { text(model.displaySettings, "noise_mode") }, set: { model.send("device.noise", ["mode": $0]) })) {
                    if !availableNoiseOptions.contains(where: { $0.0 == text(model.displaySettings, "noise_mode") }) { Text(model.unavailable).tag("").disabled(true) }
                    ForEach(availableNoiseOptions, id: \.0) { Text($0.1).tag($0.0) }
                }.pickerStyle(.radioGroup).labelsHidden().disabled(!model.canControl)
            } else if key == "equalizer" {
                VStack(spacing: 3) {
                    ForEach(Array(eqOptions.enumerated()), id: \.offset) { option in
                        Button { model.send("device.equalizer", ["preset": option.offset]) } label: {
                            HStack(spacing: 12) {
                                Text(option.element).fontWeight(eqPreset == option.offset ? .medium : .regular)
                                Spacer()
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                    .opacity(eqPreset == option.offset ? 1 : 0).accessibilityHidden(true)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                            .background(eqPreset == option.offset ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain).disabled(!model.canControl)
                            .accessibilityValue(eqPreset == option.offset ? "Selecionado" : "")
                    }
                }
                if flag(model.device, "supports_custom_eq") {
                    Divider()
                    NativeCustomEqualizerEditor(model: model).id(text(model.switching, "selected_buds"))
                }
            } else if key == "levels" {
                NativeNoiseLevelEditor(model: model)
            } else {
                if flag(model.displaySettings, "media_controls_mixed") { Text("Gestos de mídia personalizados").font(.caption).foregroundStyle(.secondary) }
                else if boolean(model.displaySettings, "media_controls_enabled") == nil { Text(model.unavailable).font(.caption).foregroundStyle(.secondary) }
                        HStack {
                            Text("Controles de mídia")
                            Spacer()
                            Toggle("Controles de mídia", isOn: Binding(get: { flag(model.displaySettings, "media_controls_enabled") }, set: { model.send("device.media_controls", ["enabled": $0]) }))
                                .labelsHidden().toggleStyle(.switch).disabled(!canTouch)
                        }
                Text("Pinça simples, dupla, tripla e deslizar. Pressionar e segurar e os gestos de chamadas continuam disponíveis.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Divider()
                gestureToggle("Pinça simples", detail: "Reproduzir ou pausar", key: "single_pinch")
                gestureToggle("Pinça dupla", detail: "Próxima faixa", key: "double_pinch")
                gestureToggle("Pinça tripla", detail: "Faixa anterior", key: "triple_pinch")
                gestureToggle("Deslizar", detail: "Ajustar o volume", key: "swipe")
                Divider()
                gestureToggle("Atender ou encerrar", detail: "Pinçar durante chamadas", key: "call_double_pinch")
                gestureToggle("Recusar chamadas", detail: "Pinçar e segurar", key: "call_hold")
            }
            if !flag(model.device, "busy") && (!model.canControl || (key == "touch" && !canTouch)) {
                if !model.connected { Text("Conecte os Buds ao Mac para configurar.").font(.caption).foregroundStyle(.secondary) }
                Button("Ler controles") { model.send("device.refresh") }.disabled(!model.canRefresh)
            }
        }.font(.system(size: 13)).controlSize(.regular).padding(20)
            .frame(width: key == "equalizer" || key == "touch" ? 320 : 280).preferredColorScheme(.dark)
    }
    @ViewBuilder private func gestureToggle(_ title: String, detail: String, key: String) -> some View {
        let controls = model.displaySettings["touch_controls"] as? [String: Any] ?? [:]
        if let enabled = boolean(controls, key) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(title, isOn: Binding(get: { enabled }, set: { model.send("device.gesture", ["gesture": key, "enabled": $0]) }))
                    .labelsHidden().toggleStyle(.switch).disabled(!canTouch)
                    .accessibilityHint(detail)
            }.padding(.vertical, 3)
        } else {
            HStack { Text(title); Spacer(); Text(model.unavailable).foregroundStyle(.secondary) }
                .font(.callout)
        }
    }
    private var eqValue: String {
        if flag(model.displaySettings, "equalizer_custom") { return "Personalizado" }
        if boolean(model.displaySettings, "equalizer_enabled") == false { return "Desligado" }
        return eqPreset.map { eqOptions[$0] } ?? model.unavailable
    }
    private var eqPreset: Int? {
        guard let value = number(model.displaySettings, "equalizer"), value.rounded() == value, (0...5).contains(value) else { return nil }
        return Int(value)
    }
    private var canTouch: Bool { model.canControl && boolean(model.device, "can_touch") == true }
    private var tools: [String: Any] { model.device["tools"] as? [String: Any] ?? [:] }
    fileprivate var toolsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Buscar os Buds", systemImage: "speaker.wave.2")
                Spacer()
                Picker("Lado da busca", selection: $model.findTarget) {
                    Text("Ambos").tag("both"); Text("Esquerdo").tag("left"); Text("Direito").tag("right")
                }.labelsHidden().frame(width: 110).disabled(flag(tools, "active"))
            }
            Text("Retire os dois fones dos ouvidos e deixe-os fora do estojo para fazer o som de busca.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if flag(tools, "active") && text(tools, "kind") == "find" {
                Text("Procurando os Buds…").font(.caption).foregroundStyle(.secondary)
                Button("Parar busca") { model.send("device.tools_cancel") }
            } else {
                Button("Iniciar busca") { model.send("device.find", ["target": model.findTarget]) }
                    .disabled(!flag(tools, "can_find") || !model.canRefresh)
            }
            Divider()
            Text("Teste de vedação").font(.system(size: 13, weight: .medium))
            Text("Coloque os dois fones nos ouvidos e fique em um ambiente silencioso.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let result = tools["fit_result"] as? [String: Any] {
                HStack(alignment: .top, spacing: 20) {
                    fitReading("Esquerdo", result: text(result, "left"))
                    fitReading("Direito", result: text(result, "right"))
                }
                if let date = number(tools, "fit_observed_at") {
                    Text("Último teste · \(Date(timeIntervalSince1970: date).formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Testar vedação") { model.send("device.fit_test") }
                .disabled(!flag(tools, "can_fit") || !model.canRefresh)
            if flag(tools, "active") && text(tools, "kind") == "fit" {
                Text(text(model.device, "status", "Operação em andamento…"))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Parar ferramenta") { model.send("device.tools_cancel") }
            }
        }.font(.system(size: 12)).tint(.primary).id("buds-tools")
    }
    private func fitReading(_ title: String, result: String) -> some View {
        let value = result == "good" ? "Bom encaixe" : result == "bad" ? "Ajuste a ponteira" : "Não foi possível medir"
        return VStack(alignment: .leading, spacing: 3) {
            Text(title).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var observedSettings: [String: Any] { model.displaySettings["settings"] as? [String: Any] ?? [:] }
    @ViewBuilder private func settingToggle(_ title: String, key: String) -> some View {
        if let value = boolean(observedSettings, key) {
            HStack {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Toggle(title, isOn: Binding(get: { boolean(observedSettings, key) ?? value },
                    set: { model.send("device.setting", ["key": key, "value": $0]) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.regular).disabled(!model.canControl)
            }
        } else {
            HStack {
                Text(title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Text(model.unavailable)
            }.foregroundStyle(.secondary).accessibilityElement(children: .combine)
        }
    }
    private var deviceSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            stereoBalance
            settingToggle("Detectar conversas", key: "conversation_detection")
            if let timeout = number(observedSettings, "conversation_timeout"), timeout.rounded() == timeout, (0...2).contains(timeout) {
                HStack {
                    Text("Retomar após")
                    Spacer(minLength: 12)
                    Picker("Retomar após", selection: Binding(get: { Int(number(observedSettings, "conversation_timeout") ?? timeout) },
                        set: { model.send("device.setting", ["key": "conversation_timeout", "value": $0]) })) {
                        Text("5 segundos").tag(0)
                        Text("10 segundos").tag(1)
                        Text("15 segundos").tag(2)
                    }.labelsHidden().fixedSize()
                        .disabled(!model.canControl || boolean(observedSettings, "conversation_detection") != true)
                }
            } else {
                HStack { Text("Retomar após"); Spacer(minLength: 12); Text(model.unavailable) }
                    .foregroundStyle(.secondary).accessibilityElement(children: .combine)
            }
            settingToggle("Controle de ruído com um fone", key: "one_earbud_noise_control")
            Text("Durante chamadas").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).padding(.top, 4)
            settingToggle("Ouvir minha voz nas chamadas", key: "sidetone")
            settingToggle("Chamadas nos Buds", key: "call_audio_to_buds")
            if !model.connected {
                Text("Conecte os Buds ao Mac para configurar.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private var stereoBalance: some View {
        if let value = number(observedSettings, "stereo_balance"), value.rounded() == value, (0...32).contains(value) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Equilíbrio entre os fones")
                    Spacer()
                    Text(balanceEditing ? balanceDescription(balanceDraft) : balanceDescription(value))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $balanceDraft, in: 0...32, step: 1, onEditingChanged: { editing in
                    balanceEditing = editing
                    if !editing && model.canControl && balanceDraft != value {
                        model.send("device.setting", ["key": "stereo_balance", "value": Int(balanceDraft)])
                    }
                }).accessibilityLabel("Equilíbrio entre os fones")
                    .accessibilityValue(balanceDescription(balanceDraft)).disabled(!model.canControl)
                HStack { Text("Esquerdo"); Spacer(); Text("Direito") }.font(.caption).foregroundStyle(.secondary)
            }
            .onAppear { balanceDraft = value }
            .onChange(of: value) { _, next in if !balanceEditing { balanceDraft = next } }
            Divider()
        }
    }
    private func balanceDescription(_ value: Double) -> String {
        let offset = Int(value.rounded()) - 16
        if offset == 0 { return "Centralizado" }
        return "\(abs(offset)) · \(offset < 0 ? "Esquerdo" : "Direito")"
    }
    private func tile(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: symbol).font(.system(size: 18)).frame(height: 22).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if title != "Ambiente" { Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary) }
            }
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.system(size: 11, weight: .medium))
                .lineLimit(2, reservesSpace: true).fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
            .modifier(NativeBudsTileSurface())
            .contentShape(RoundedRectangle(cornerRadius: 14))
    }
    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                if flag(model.account, "connected") || flag(model.account, "can_cancel") { model.accountOpen.toggle() }
                else { model.accountOpen = true; model.send("account.sign_in") }
            } label: {
                HStack(spacing: 9) {
                    avatar
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text(model.account, "name", "Samsung Account")).font(.system(size: 12, weight: .medium))
                            .underline(accountFocused, color: .secondary).lineLimit(1)
                        Text(flag(model.account, "connected") ? "Conta conectada" : "Entrar com Samsung Account").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }.buttonStyle(.plain).focused($accountFocused).focusEffectDisabled()
                .accessibilityLabel(flag(model.account, "connected") ? "Samsung Account, mostrar ou ocultar detalhes" : "Entrar com Samsung Account")
            Spacer(minLength: 4)
            Button { model.send("device.refresh") } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 26) }
                .modifier(NativeBudsActionStyle()).buttonBorderShape(.circle)
                .disabled(!model.canRefresh).help("Ler controles dos Buds").accessibilityLabel("Atualizar controles dos Buds")
            Button { model.settingsOpen.toggle() } label: { Image(systemName: "slider.horizontal.3").frame(width: 24, height: 26) }
                .modifier(NativeBudsActionStyle()).buttonBorderShape(.circle)
                .help("Configurações dos Buds e alternância").accessibilityLabel("Mostrar ou ocultar configurações dos Buds e alternância")
        }
    }
    private var avatar: some View {
        Group {
            if let image = model.avatar { Image(nsImage: image).resizable().scaledToFill() }
            else { Text(text(model.account, "initials", "SA")).font(.system(size: 11, weight: .medium)).frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
        }.frame(width: 30, height: 30).clipShape(Circle()).accessibilityHidden(true)
    }
    private func errorView(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if model.actionError != nil {
                Button { model.actionError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).accessibilityLabel("Dispensar mensagem")
            }
        }.font(.system(size: 12)).accessibilityElement(children: .contain)
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Divider()
            Text("Ajustes").font(.system(size: 18, weight: .semibold))
            DisclosureGroup(isExpanded: $model.controlsExpanded) {
                deviceSettings.padding(.top, 12)
            } label: {
                Label("Som e controles", systemImage: "earbuds").fontWeight(.medium).padding(.vertical, 4)
            }
            Divider()
            switching
            Divider()
            DisclosureGroup(isExpanded: $model.toolsExpanded) {
                toolsSection.padding(.top, 12)
            } label: {
                Label("Encontrar e testar", systemImage: "location.magnifyingglass").fontWeight(.medium).padding(.vertical, 4)
            }
            Divider()
            DisclosureGroup(isExpanded: $model.updatesExpanded) {
                appUpdates.padding(.top, 12)
                Divider().padding(.vertical, 8)
                firmwareUpdates
            } label: {
                Label("Atualizações", systemImage: "arrow.down.circle").fontWeight(.medium).padding(.vertical, 4)
            }
            Divider()
            if flag(model.switching, "recovery_pending") {
                Label("Restaurando o som do Mac automaticamente…", systemImage: "speaker.wave.2")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button("Sair do Buds") { model.send("app.quit") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).padding(.vertical, 3)
        }.font(.system(size: 12))
    }
    private var appUpdates: some View {
        let update = model.root["app_update"] as? [String: Any] ?? [:]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Buds para macOS").fontWeight(.medium)
                Spacer()
                Text(text(update, "current_version", "Versão de desenvolvimento")).foregroundStyle(.secondary)
            }
            if flag(update, "configured") && flag(update, "framework_available") {
                Toggle("Buscar atualizações automaticamente", isOn: Binding(
                    get: { flag(update, "automatically_checks") },
                    set: { model.send("app.update_automatic", ["enabled": $0]) }))
                    .toggleStyle(.switch).disabled(!flag(update, "can_set_automatic"))
                Toggle("Baixar atualizações automaticamente", isOn: Binding(
                    get: { flag(update, "automatically_downloads") },
                    set: { model.send("app.update_downloads", ["enabled": $0]) }))
                    .toggleStyle(.switch).disabled(!flag(update, "automatically_checks") || !flag(update, "can_set_downloads"))
                Button("Buscar atualização") { model.send("app.update_check") }
                    .disabled(!flag(update, "can_check"))
                Text(appUpdateStatus(update))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("As atualizações do app ainda não foram publicadas.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func appUpdateStatus(_ update: [String: Any]) -> String {
        switch text(update, "status") {
        case "checking": return "Buscando uma nova versão…"
        case "update_available": return "Uma nova versão está disponível."
        case "downloading": return "Baixando atualização…"
        case "downloaded": return "Atualização baixada. A instalação aguarda o app poder reiniciar."
        case "waiting_for_safe_install": return "A instalação aguarda o fim da reprodução ou da chamada."
        case "preparing_shutdown", "preparing_installation": return "Preparando o app para atualizar…"
        case "installing": return "Instalando atualização…"
        case "no_update": return "Você está usando a versão mais recente compatível."
        case "error": return "Não foi possível atualizar. Confira a internet e tente novamente."
        case "cancelled": return "Atualização cancelada."
        default: return "As atualizações são verificadas pelo próprio BudsClient."
        }
    }
    private var firmwareUpdates: some View {
        let firmware = model.root["firmware_update"] as? [String: Any] ?? [:]
        return VStack(alignment: .leading, spacing: 10) {
            Text("Firmware dos Buds").fontWeight(.medium)
            HStack {
                Text("Versão instalada"); Spacer()
                Text(text(model.device, "firmware_version", "Sem leitura")).foregroundStyle(.secondary)
            }
            HStack {
                Button("Consultar firmware") { model.send("firmware.check") }
                    .disabled(!flag(firmware, "available") || flag(firmware, "busy"))
            }
            if flag(firmware, "busy") {
                HStack { ProgressView().controlSize(.small); Text("Consultando o catálogo…") }.foregroundStyle(.secondary)
            } else if !text(firmware, "error").isEmpty {
                Text(text(firmware, "error")).foregroundStyle(.secondary)
            } else if let versions = firmware["versions"] as? [[String: Any]], let latest = versions.first {
                HStack { Text("Última no catálogo"); Spacer(); Text(text(latest, "build")).foregroundStyle(.secondary) }
                if boolean(firmware, "has_update") == true {
                    Text("Há uma versão mais recente para estes Buds.").foregroundStyle(.secondary)
                } else if boolean(firmware, "has_update") == false {
                    Text("Nenhuma versão mais recente foi encontrada para a mesma região.").foregroundStyle(.secondary)
                } else {
                    Text("Leia a versão instalada para comparar com o catálogo.").foregroundStyle(.secondary)
                }
            }
            Text("A instalação de firmware pelo Mac ainda está em validação. Para instalar agora, use o Galaxy Wearable.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var account: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Samsung Account").font(.system(size: 16, weight: .semibold))
            if flag(model.account, "can_cancel") {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(text(model.account, "display_status", "Conectando sua conta…")).foregroundStyle(.secondary)
                }
                Button("Cancelar") { model.send("account.cancel") }
            } else if !flag(model.account, "connected") {
                Text("Entre para usar a alternância entre seus dispositivos Galaxy.")
                    .foregroundStyle(.secondary)
                Button("Entrar com Samsung Account") { model.send("account.sign_in") }
                    .disabled(!flag(model.account, "can_sign_in") || model.readFailed)
            } else {
                Label("Conta conectada", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                if boolean(model.account, "setup_ready") == false {
                    Text(text(model.account, "display_status", "Concluindo a configuração da conta…")).foregroundStyle(.secondary)
                    Button("Concluir conexão") { model.send("account.sign_in") }
                        .disabled(!flag(model.account, "can_sign_in") || model.readFailed)
                }
            }
            if !text(model.account, "display_error").isEmpty {
                Text(text(model.account, "display_error")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if flag(model.account, "needs_identity") {
                Text("A Samsung precisa confirmar o e-mail ou telefone desta conta.").foregroundStyle(.secondary)
                TextField("E-mail ou telefone da conta", text: $model.identity).textFieldStyle(.roundedBorder).focused($identityFocused)
                    .onSubmit { if flag(model.account, "can_confirm_identity") && !model.readFailed { model.send("account.identity", ["identity": model.identity]) } }
                Button("Continuar") { model.send("account.identity", ["identity": model.identity]) }
                    .disabled(!flag(model.account, "can_confirm_identity") || model.readFailed)
            }
        }
    }
}

@MainActor private struct NativeNoiseLevelEditor: View {
    @ObservedObject var model: BudsPanelModel
    var body: some View {
        let levels = model.displaySettings["levels"] as? [String: Any] ?? [:]
        VStack(alignment: .leading, spacing: 16) {
            ForEach(["ambient", "anc"], id: \.self) { kind in
                if let info = levels[kind] as? [String: Any],
                   let value = number(info, "value"), let maximum = number(info, "maximum"),
                   maximum >= 1, maximum <= 4 {
                    NativeNoiseLevelRow(model: model, kind: kind, value: Int(value), maximum: Int(maximum))
                }
            }
            if levels.isEmpty { Text("Os níveis não estão disponíveis na leitura atual.").foregroundStyle(.secondary) }
        }
    }
}

@MainActor private struct NativeNoiseLevelRow: View {
    @ObservedObject var model: BudsPanelModel
    let kind: String
    let value: Int
    let maximum: Int
    @State private var draft = 0.0
    @State private var editing = false
    private var activeMode: Bool { text(model.displaySettings, "noise_mode") == (kind == "ambient" ? "ambient" : "anc") }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(kind == "ambient" ? "Som ambiente" : "Cancelamento de ruído").fontWeight(.medium)
            if maximum == 1 {
                Picker("Intensidade", selection: Binding(get: { value }, set: {
                    model.send("device.level", ["kind": kind, "value": $0])
                })) { Text("Baixa").tag(0); Text("Alta").tag(1) }
                    .pickerStyle(.segmented).labelsHidden()
            } else {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { editing ? draft : Double(value) }, set: {
                        draft = $0
                        // Keyboard and accessibility adjustments do not begin a drag.
                        if !editing, Int($0) != value { model.send("device.level", ["kind": kind, "value": Int($0)]) }
                    }),
                        in: 0...Double(maximum), step: 1, onEditingChanged: { began in
                            if began { draft = Double(value); editing = true }
                            else {
                                editing = false
                                if Int(draft) != value { model.send("device.level", ["kind": kind, "value": Int(draft)]) }
                            }
                        }).accessibilityLabel(kind == "ambient" ? "Intensidade do som ambiente" : "Intensidade do cancelamento de ruído")
                    Text("\(Int(editing ? draft : Double(value)) + 1)/\(maximum + 1)").monospacedDigit()
                }
            }
            if !activeMode { Text(kind == "ambient" ? "Ative Som ambiente para ajustar." : "Ative ANC para ajustar.").font(.caption).foregroundStyle(.secondary) }
        }.disabled(!model.canControl || !activeMode)
    }
}

@MainActor private struct NativeCustomEqualizerEditor: View {
    @ObservedObject var model: BudsPanelModel
    @State private var expanded = false
    @State private var draft: [Double] = []
    private let frequencies = ["63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    private var reading: [Int]? {
        guard let values = model.device["custom_eq_bands"] as? [Any], values.count == 9 else { return nil }
        let parsed = values.compactMap { value -> Int? in
            guard let n = number(["value": value], "value"), n.rounded() == n, (-10...10).contains(n) else { return nil }
            return Int(n)
        }
        return parsed.count == 9 ? parsed : nil
    }
    var body: some View {
        DisclosureGroup("Curva de nove bandas", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if draft.count == 9, reading != nil {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(0..<9, id: \.self) { index in
                                HStack(spacing: 8) {
                                    Text(frequencies[index]).frame(width: 28, alignment: .trailing)
                                    Slider(value: Binding(get: { draft.indices.contains(index) ? draft[index] : 0 },
                                        set: { if draft.indices.contains(index) { draft[index] = $0 } }), in: -10...10, step: 1)
                                        .accessibilityLabel("\(frequencies[index]) hertz")
                                        .disabled(!canWrite)
                                    Text("\(Int(draft[index]))").monospacedDigit().frame(width: 24, alignment: .trailing)
                                }
                            }
                        }.font(.caption)
                    }.scrollIndicators(.never).frame(height: 230)
                    Text("Ganho em dB. A curva só é enviada ao clicar em Aplicar.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Leia a curva salva nos Buds para personalizar o equalizador.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Ler curva") { model.send("device.custom_eq_read") }
                        .disabled(!model.canRefresh)
                    Spacer()
                    Button("Aplicar") { model.send("device.custom_eq", ["bands": draft.map { Int($0) }]) }
                        .disabled(!canWrite || draft.count != 9 || reading == nil)
                }.modifier(NativeBudsActionStyle())
            }.padding(.top, 10)
        }
        .onAppear { draft = reading?.map(Double.init) ?? [] }
        .onChange(of: reading) { _, next in draft = next?.map(Double.init) ?? [] }
    }
    // Every operation bootstraps and verifies physical identity afresh. Do not
    // expire the user's local edit while they are adjusting nine sliders.
    private var canWrite: Bool { model.canRefresh && model.connected }
}

/// System glass buttons on current macOS, with native bordered controls on older releases.
private struct NativeBudsActionStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else { content.buttonStyle(.bordered) }
    }
}

private struct NativeBudsTileSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
        } else {
            content.background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

/// The popover owns its outline. One native blur surface and a stable ink wash
/// avoid stacking a second rounded glass frame inside the system container.
@MainActor private final class NativePanelController: NSViewController {
    private let content: NSHostingController<BudsPanel>
    init(model: BudsPanelModel) {
        content = NSHostingController(rootView: BudsPanel(model: model))
        content.sizingOptions = []
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let material = NSVisualEffectView()
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.appearance = NSAppearance(named: .darkAqua)
        view = material
        // AppKit owns both layers, with actual edge constraints. The prior
        // representable/SwiftUI overlay was flattened into the popover's gray
        // backdrop instead of tinting its live visual-effect material.
        let ink = NSView()
        ink.wantsLayer = true
        ink.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        addChild(content)
        content.view.wantsLayer = true
        content.view.layer?.backgroundColor = NSColor.clear.cgColor
        content.view.layer?.isOpaque = false
        for child in [ink, content.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            material.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: material.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: material.trailingAnchor),
                child.topAnchor.constraint(equalTo: material.topAnchor),
                child.bottomAnchor.constraint(equalTo: material.bottomAnchor)
            ])
        }
    }
}

#if BUDS_PANEL_PREVIEW
/// This entry point exists only in the separate preview executable. Neither
/// NativeIntegration nor a Bluetooth/audio implementation is linked into it.
@MainActor enum NativeBudsPanelPreview {
    static func controller(state: [String: Any], resources: URL, settings: Bool = false,
                           account: Bool = false, readFailed: Bool = false,
                           scrollTarget: String? = nil) -> NSViewController {
        let model = BudsPanelModel(callback: { _ in })
        model.root = state; model.previewResources = resources
        model.settingsOpen = settings; model.accountOpen = account; model.readFailed = readFailed
        model.previewScrollTarget = scrollTarget
        return NativePanelController(model: model)
    }
    static func gestures(state: [String: Any]) -> NSViewController {
        let model = BudsPanelModel(callback: { _ in }); model.root = state
        let controller = NSHostingController(rootView: BudsPanel(model: model).featureOptions("touch", title: "Gestos")
            .modifier(NativeBudsActionStyle()).controlSize(.regular).tint(.primary)
            .background(Color(nsColor: .windowBackgroundColor)))
        controller.sizingOptions = []
        return controller
    }
    static func tools(state: [String: Any]) -> NSViewController {
        let model = BudsPanelModel(callback: { _ in }); model.root = state
        let controller = NSHostingController(rootView: BudsPanel(model: model).toolsSection.modifier(NativeBudsActionStyle()).controlSize(.regular).padding(20)
            .frame(width: 392, height: 420, alignment: .topLeading)
            .preferredColorScheme(.dark).background(Color(nsColor: .windowBackgroundColor)))
        controller.sizingOptions = []
        return controller
    }
}
#else
@MainActor private final class BudsMenuBarController: NSObject, NSPopoverDelegate {
    let model: BudsPanelModel
    let popover = NSPopover()
    let statusItem: NSStatusItem
    private let callback: PanelAction
    init(callback: @escaping PanelAction) {
        self.callback = callback
        model = BudsPanelModel(callback: callback)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "earbuds", accessibilityDescription: "Buds")
            button.image?.isTemplate = true
            button.toolTip = "Buds · controles e alternância"
            button.setAccessibilityLabel("Buds, mostrar controles")
            button.target = self; button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.delegate = self
        popover.contentViewController = NativePanelController(model: model)
        resize(height: 560)
        // Prepare account/device models without requesting the headset connection.
        model.refresh()
    }
    func resize(height: CGFloat) {
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let maximum = max(300, (screen?.visibleFrame.height ?? 800) - 28)
        popover.contentSize = NSSize(width: 440, height: min(height, maximum))
    }
    func show(toggle: Bool = false) {
        if toggle && popover.isShown { popover.performClose(nil); return }
        guard !popover.isShown, let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        #if DEBUG
        if popover.behavior == .applicationDefined { popover.contentViewController?.view.window?.orderFrontRegardless() }
        #endif
        model.start()
        "{\"action\":\"ui.panel_visibility\",\"open\":true}".withCString { callback($0) }
    }
    @objc private func toggle() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "Abrir controles dos Buds", action: #selector(open), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Sair do Buds", action: #selector(quit), keyEquivalent: "q").target = self
            if let button = statusItem.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY), in: button) }
        } else { show(toggle: true) }
    }
    @objc private func open() { show() }
    @objc private func quit() { "{\"action\":\"app.quit\"}".withCString { callback($0) } }
    func popoverDidClose(_ notification: Notification) {
        model.stop(); model.feature = nil
        "{\"action\":\"ui.panel_visibility\",\"open\":false}".withCString { callback($0) }
    }
}

@_cdecl("buds_menubar_start")
public func budsMenuBarStart(_ callback: (@convention(c) (UnsafePointer<CChar>?) -> Void)?) -> UnsafeMutableRawPointer? {
    guard let callback, Thread.isMainThread else { return nil }
    let address = MainActor.assumeIsolated { UInt(bitPattern: Unmanaged.passRetained(BudsMenuBarController(callback: callback)).toOpaque()) }
    return UnsafeMutableRawPointer(bitPattern: address)
}
@_cdecl("buds_menubar_show")
public func budsMenuBarShow(_ pointer: UnsafeMutableRawPointer?, _ toggle: Int32) {
    guard let pointer, Thread.isMainThread else { return }
    MainActor.assumeIsolated { Unmanaged<BudsMenuBarController>.fromOpaque(pointer).takeUnretainedValue().show(toggle: toggle != 0) }
}
@_cdecl("buds_menubar_error")
public func budsMenuBarError(_ pointer: UnsafeMutableRawPointer?, _ message: UnsafePointer<CChar>?) {
    guard let pointer, let message, Thread.isMainThread else { return }
    MainActor.assumeIsolated { Unmanaged<BudsMenuBarController>.fromOpaque(pointer).takeUnretainedValue().model.actionError = String(cString: message) }
}
#if DEBUG
@_cdecl("buds_menubar_review_stage")
public func budsMenuBarReviewStage(_ pointer: UnsafeMutableRawPointer?, _ stage: Int32) -> Int32 {
    guard let pointer, Thread.isMainThread else { return 0 }
    return MainActor.assumeIsolated {
        let controller = Unmanaged<BudsMenuBarController>.fromOpaque(pointer).takeUnretainedValue()
        let model = controller.model
        if stage == 3 { return model.actionError?.hasPrefix("Mensagem de teste visual:") == true ? 1 : 0 }
        model.clearReviewFixture()
        if stage == 9 || stage == 10 { model.installReviewFixture(buds4: stage == 10) }
        if (6...8).contains(stage) {
            // Explicit DEBUG visual fixtures. They never read/write a device or
            // assert that a real handoff took place.
            let address = "AA:BB:CC:DD:EE:01"
            let at = ProcessInfo.processInfo.systemUptime
            ConnectionHUD.shared.observeLink(address: address, connected: false, at: at)
            let event = NativeConnectionBannerEvent(address: address, name: "Teste visual · Galaxy Buds3 Pro",
                kind: stage == 8 ? .departedFromMac(destination: nil) : stage == 7 ? .acquiredFromOtherDevice : .directMacConnection,
                occurredAt: at)
            let battery = BudsBatterySnapshot(address: address, name: event.name, model: "Buds3Pro", icon: "Buds3ProSilver",
                left: 85, right: 82, casePercent: 60, observedAt: Date().timeIntervalSince1970)
            ConnectionHUD.shared.show(event: event, battery: battery, duration: 12)
            return 1
        }
        model.settingsOpen = stage == 1; model.accountOpen = stage == 1
        model.actionError = stage == 2 ? "Mensagem de teste visual: a ação não foi concluída. Verifique a conexão e tente novamente." : nil
        model.feature = stage == 4 ? "noise" : nil
        controller.resize(height: stage == 1 ? 1050 : stage == 5 ? 500 : 520)
        // Hold only DEBUG visual QA open while the capture/inspection process
        // is foreground. Production always uses native transient dismissal.
        controller.popover.behavior = .applicationDefined
        controller.show()
        controller.popover.contentViewController?.view.window?.orderFrontRegardless()
        return 1
    }
}
#endif

#endif // BUDS_PANEL_PREVIEW
#endif
