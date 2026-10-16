import AppKit
import SwiftUI

struct ConnectionHUDContent: View {
    let name: String
    let destination: String
    let battery: BudsBatterySnapshot?
    let resourceDirectory: URL?
    var systemImage: String = "laptopcomputer"
    var portuguese: Bool = Locale.preferredLanguages.first?.hasPrefix("pt") == true
    private func hudText(_ pt: String, _ en: String) -> String { portuguese ? pt : en }
    private var prefix: String? {
        let profile = NativeBudsProfile.resolve(model: battery?.model, name: name)
        // Keep existing client artwork for earlier models as well. The cache
        // prefix is path-validated; known profiles reject another model's art.
        if profile.model != nil, !profile.artworkPrefixes.isEmpty {
            return profile.artwork(battery?.iconPrefix) ?? profile.defaultArtwork
        }
        return battery?.iconPrefix ?? profile.defaultArtwork
    }
    private func image(_ side: Int) -> NSImage? {
        guard let prefix, let resourceDirectory else { return nil }
        return NSImage(contentsOf: resourceDirectory.appendingPathComponent("BudsImages/\(prefix)-\(side).png"))
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let left = image(0), let right = image(1) {
                    Image(nsImage: left).resizable().scaledToFit().frame(width: 78, height: 100)
                    Image(nsImage: right).resizable().scaledToFit().frame(width: 78, height: 100)
                } else {
                    Image(systemName: "earbuds").font(.system(size: 64, weight: .regular)).frame(height: 100)
                }
            }.accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(name).font(.system(size: 19, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                Label(destination, systemImage: systemImage)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                if let battery, battery.left != nil || battery.right != nil || battery.casePercent != nil {
                    if let left = battery.left { level(hudText("E", "L"), left) }
                    if let right = battery.right { level(hudText("D", "R"), right) }
                    if let casePercent = battery.casePercent { level(hudText("Estojo", "Case"), casePercent) }
                }
            }.frame(minHeight: 15)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .frame(width: 340, height: 248)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .combine)
    }
    private func level(_ side: String, _ rawValue: Int?) -> some View {
        let value = rawValue.flatMap { (0...100).contains($0) ? $0 : nil }
        let label = side == hudText("E", "L") ? hudText("Esquerdo", "Left earbud")
            : side == hudText("D", "R") ? hudText("Direito", "Right earbud") : hudText("Estojo", "Case")
        return HStack(spacing: 4) {
            Image(systemName: value.map { $0 <= 20 ? "battery.25percent" : $0 <= 50 ? "battery.50percent" : $0 <= 75 ? "battery.75percent" : "battery.100percent" } ?? "minus")
                .foregroundStyle(value.map { $0 <= 20 } == true ? Color.orange : Color.primary)
            Text("\(side) \(value.map { "\($0)%" } ?? "—")").monospacedDigit()
        }.font(.system(size: 12, weight: .medium))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(label) \(value.map { "\($0)%" } ?? hudText("indisponível", "unavailable"))")
    }
}

@MainActor private final class ConnectionHUDState: ObservableObject {
    @Published var battery: BudsBatterySnapshot?
    init(_ battery: BudsBatterySnapshot?) { self.battery = battery }
}
private struct ConnectionHUDLiveContent: View {
    let name: String
    let destination: String
    let systemImage: String
    @ObservedObject var state: ConnectionHUDState
    let resourceDirectory: URL?
    var body: some View { ConnectionHUDContent(name: name, destination: destination, battery: state.battery,
        resourceDirectory: resourceDirectory, systemImage: systemImage) }
}

private final class ConnectionHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A transient, nonactivating system-material panel. Never steals keyboard focus.
@MainActor final class ConnectionHUD {
    static let shared = ConnectionHUD()
    private var panel: NSPanel?
    private var dismiss: Task<Void, Never>?
    private var batteryRefresh: Task<Void, Never>?
    private var bannerPolicy = NativeConnectionBannerPolicy()
    /// Pure, in-memory observation supplied by the embedded session. This never
    /// opens a settings channel, polls a radio or changes playback/ownership.
    var batteryProvider: (String) -> BudsBatterySnapshot? = { _ in nil }

    private func currentBattery(address: String, retaining previous: BudsBatterySnapshot?) -> BudsBatterySnapshot? {
        BudsBatterySnapshot.newestCurrent([batteryProvider(address), previous,
            BudsBatterySnapshot.load(address: address)], address: address)
    }

    /// Wire the passive monitor here as well as to show(event:), so real link
    /// losses rearm a reconnect without announcing an unproven remote handoff.
    func observeLink(address: String, connected: Bool, at time: TimeInterval) {
        bannerPolicy.observeLink(address: address, connected: connected, at: time)
    }

    func showConnected(address: String, name: String, galaxy: Bool) {
        show(event: .init(address: address, name: name,
            kind: galaxy ? .departedFromMac(destination: nil) : .directMacConnection,
            occurredAt: ProcessInfo.processInfo.systemUptime))
    }

    /// Legacy verified model callback, retained for root integration. Unknown
    /// text is ignored; a generic Galaxy label never becomes a named destination.
    func show(name: String, destination: String, battery: BudsBatterySnapshot?, duration: TimeInterval = 4, resourceDirectory: URL? = Bundle.main.resourceURL, address: String? = nil) {
        guard let address = address ?? battery?.address,
              let event = NativeConnectionBannerEvent.legacy(address: address, name: name,
                destination: destination, occurredAt: ProcessInfo.processInfo.systemUptime) else { return }
        show(event: event, battery: battery, duration: duration, resourceDirectory: resourceDirectory)
    }

    func show(event: NativeConnectionBannerEvent, battery: BudsBatterySnapshot? = nil,
              duration: TimeInterval = 4, resourceDirectory: URL? = Bundle.main.resourceURL) {
        guard duration.isFinite, duration > 0,
              let presentation = bannerPolicy.presentation(for: event) else { return }
        let battery = currentBattery(address: event.address, retaining: battery)
        present(presentation, battery: battery, duration: min(duration, 30), resourceDirectory: resourceDirectory)
    }

    private func present(_ presentation: NativeConnectionBannerPresentation, battery: BudsBatterySnapshot?,
                         duration: TimeInterval, resourceDirectory: URL?) {
        let name = presentation.event.name, destination = presentation.destination, address = presentation.event.address
        dismiss?.cancel(); batteryRefresh?.cancel()
        panel?.orderOut(nil)
        let panel = ConnectionHUDPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 248),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let material = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 248))
        material.material = .hudWindow; material.blendingMode = .behindWindow; material.state = .active
        material.appearance = NSAppearance(named: .darkAqua)
        material.wantsLayer = true; material.layer?.cornerRadius = 20; material.layer?.masksToBounds = true
        // Same ink wash as the native panel, with one rounded material surface
        // and no additional SwiftUI outline or nested glass border.
        let ink = NSView(frame: material.bounds)
        ink.autoresizingMask = [.width, .height]; ink.wantsLayer = true
        ink.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        material.addSubview(ink)
        let state = ConnectionHUDState(battery)
        let view = NSHostingView(rootView: ConnectionHUDLiveContent(name: name, destination: destination,
            systemImage: presentation.systemImage, state: state, resourceDirectory: resourceDirectory))
        view.frame = material.bounds; view.autoresizingMask = [.width, .height]; material.addSubview(view)
        panel.contentView = material
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - 170, y: frame.midY - 124))
        }
        panel.alphaValue = 0; panel.orderFrontRegardless(); self.panel = panel
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: name + ". " + destination, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        batteryRefresh = Task {
            for _ in 0..<Int(ceil(duration * 4)) {
                guard !Task.isCancelled else { return }
                // An expired reading disappears instead of remaining on screen
                // after a long preview or a freshness-boundary handoff.
                state.battery = currentBattery(address: address, retaining: state.battery)
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
            panel.animator().alphaValue = 1
        }
        dismiss = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard !Task.isCancelled, let panel else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: { panel.orderOut(nil) })
            self?.dismiss = nil
        }
    }
}
