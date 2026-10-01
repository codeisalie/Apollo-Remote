import AppKit
import SwiftUI

/// Visual styles for the volume HUD that appears on media-key presses.
enum VolumeHUDStyle: String, CaseIterable, Identifiable {
    case compact   // refined original — smaller, SF system type
    case minimal   // thin bar + value only
    case bezel     // classic macOS volume bezel (centered)
    case banner    // top-center pill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Compact"
        case .minimal: return "Minimal"
        case .bezel:   return "Bezel"
        case .banner:  return "Banner"
        }
    }
}

final class VolumeOverlayController {
    static let shared = VolumeOverlayController()

    private(set) var interfaceIsOpen = false
    private var panel: NSPanel?
    private var fadeWorkItem: DispatchWorkItem?
    private var rebuildWorkItem: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []
    private weak var controller: ApolloController?

    private init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuild() })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func setInterfaceOpen(_ isOpen: Bool) {
        interfaceIsOpen = isOpen
        if isOpen { dismiss() }
    }

    func dismiss() {
        fadeWorkItem?.cancel()
        panel?.orderOut(nil)
    }

    func show(for controller: ApolloController) {
        guard UserDefaults.standard.bool(forKey: "volumeOverlayEnabled"),
              !interfaceIsOpen else { return }
        self.controller = controller
        ensurePanel()
        guard let panel else { return }

        let style = VolumeHUDStyle(rawValue: UserDefaults.standard.string(forKey: "volumeHUDStyle") ?? "compact") ?? .compact
        let view = VolumeOverlayView(
            style: style,
            deviceName: controller.deviceName,
            volumeTapered: controller.volumeTapered,
            volumeText: controller.volumeDisplay,
            muted: controller.isMuted,
            dimmed: controller.isDimmed
        )

        // Reuse the hosting view when possible so held-key updates stay smooth
        // instead of tearing down/recreating the layer tree every press.
        if let host = panel.contentView as? NSHostingView<VolumeOverlayView>,
           host.frame.size == style.panelSize {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.frame.size = style.panelSize
            panel.contentView = host
            panel.setContentSize(style.panelSize)
            position(panel, style: style)
        }

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        fadeWorkItem?.cancel()
        let fade = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                self?.panel?.animator().alphaValue = 0
            }
        }
        fadeWorkItem = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: fade)

        rebuildWorkItem?.cancel()
        let rebuild = DispatchWorkItem { [weak self] in self?.rebuild() }
        rebuildWorkItem = rebuild
        DispatchQueue.main.asyncAfter(deadline: .now() + 300, execute: rebuild)
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .statusBar
        newPanel.hidesOnDeactivate = false
        newPanel.ignoresMouseEvents = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel = newPanel
    }

    private func position(_ panel: NSPanel, style: VolumeHUDStyle) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = style.panelSize
        let origin: NSPoint
        switch style {
        case .compact, .minimal:
            origin = NSPoint(
                x: frame.maxX - size.width - 16,
                y: frame.maxY - size.height - 12
            )
        case .bezel:
            origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2 - 40
            )
        case .banner:
            origin = NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.maxY - size.height - 18
            )
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func rebuild() {
        guard let controller, panel != nil else { return }
        panel = nil
        ensurePanel()
        if controller.isConnected && controller.isDeviceOnline {
            show(for: controller)
        }
    }
}

private extension VolumeHUDStyle {
    var panelSize: NSSize {
        switch self {
        case .compact: return NSSize(width: 220, height: 32)
        case .minimal: return NSSize(width: 160, height: 28)
        case .bezel:   return NSSize(width: 168, height: 168)
        case .banner:  return NSSize(width: 320, height: 48)
        }
    }
}

// MARK: - Views

private struct VolumeOverlayView: View {
    let style: VolumeHUDStyle
    let deviceName: String
    let volumeTapered: Double
    let volumeText: String
    let muted: Bool
    let dimmed: Bool

    private var fillColor: Color {
        muted ? .red : (dimmed ? .orange : Color.primary)
    }

    var body: some View {
        switch style {
        case .compact: compactBody
        case .minimal: minimalBody
        case .bezel:   bezelBody
        case .banner:  bannerBody
        }
    }

    // Refined original — tighter padding, SF system font, less chunky.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(muted ? Color.red : Color.primary)
                Text(deviceName.isEmpty ? "Apollo" : deviceName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text(muted ? "Muted" : volumeText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            GeometryReader { geo in
                let w = max(0, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(fillColor.opacity(muted ? 0.85 : 0.9))
                        .frame(width: w * CGFloat(max(0, min(1, volumeTapered))))
                }
                .frame(width: w, height: 4)
                .clipped()
            }
            .frame(height: 4)
            .clipped()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(width: 220, height: 32)
        .clipped()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var minimalBody: some View {
        HStack(spacing: 8) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(muted ? Color.red : Color.primary)
                .fixedSize()
            GeometryReader { geo in
                let w = max(0, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(fillColor.opacity(0.9))
                        .frame(width: w * CGFloat(max(0, min(1, volumeTapered))))
                }
                .frame(width: w, height: 3)
                .clipped()
            }
            .frame(height: 3)
            .clipped()
            Text(muted ? "Mute" : volumeText)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 36, alignment: .trailing)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: 160, height: 28)
        .clipped()
        .background(.ultraThinMaterial, in: Capsule())
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var bezelBody: some View {
        VStack(spacing: 10) {
            Image(systemName: muted ? "speaker.slash.fill" : speakerSymbol)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(muted ? Color.red : Color.primary)
                .frame(height: 44)

            GeometryReader { geo in
                let w = max(0, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.15))
                    Capsule().fill(fillColor.opacity(0.95))
                        .frame(width: w * CGFloat(max(0, min(1, volumeTapered))))
                }
                .frame(width: w, height: 6)
                .clipped()
            }
            .frame(height: 6)
            .padding(.horizontal, 8)
            .clipped()

            Text(muted ? "Muted" : volumeText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 168, height: 168)
        .clipped()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }

    private var bannerBody: some View {
        HStack(spacing: 12) {
            Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(muted ? Color.red : Color.primary)
                .fixedSize()
            GeometryReader { geo in
                let w = max(0, geo.size.width)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(fillColor.opacity(0.9))
                        .frame(width: w * CGFloat(max(0, min(1, volumeTapered))))
                }
                .frame(width: w, height: 4)
                .clipped()
            }
            .frame(height: 4)
            .clipped()
            Text(muted ? "Muted" : volumeText)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(width: 320, height: 48)
        .clipped()
        .background(.ultraThinMaterial, in: Capsule())
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var speakerSymbol: String {
        if volumeTapered <= 0.001 { return "speaker.fill" }
        if volumeTapered < 0.33 { return "speaker.wave.1.fill" }
        if volumeTapered < 0.66 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
