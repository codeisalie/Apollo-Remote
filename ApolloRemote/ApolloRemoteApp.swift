import SwiftUI
import AppKit
import Combine
import WidgetKit

@main
struct ApolloRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var apollo: ApolloController?
    private var apolloCancellables = Set<AnyCancellable>()
    private var defaultsObserver: NSObjectProtocol?
    private var backendStartupCompleted = false
    private var pendingTerminationReply: NSApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            "keyboardVolumeKeysEnabled": true,
            "volumeOverlayEnabled": true,
            "volumeHUDStyle": "compact",
            "volumeStep": 3.0,
            "keyboardMuteAction": "mute",
            "appLanguage": "system",
            "notifyOnMixerStart": true,
            "notifyOnUAQuit": true,
            "volumeJumpLock": true,
            "sliderTuningProfile": "Softner",
            "showVolumePercentReadout": true,
            "showVolumeDBReadout": true
        ])

        // Migrate legacy "Slide Safety" tuning profile → Jump Lock + Instant.
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "sliderTuningProfile") == "Slide Safety" {
            defaults.set(true, forKey: "volumeJumpLock")
            defaults.set("Softner", forKey: "sliderTuningProfile")
        }

        // Permission prompts are owned by the feature that actually needs them.
        // KeyboardVolumeManager performs a single Accessibility / Device Control
        // check when it starts. Notifications are never requested at startup.

        // Keep Apollo Remote in the menu bar without showing a Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // Show the menu-bar control immediately, independent of engine startup.
        setupStatusItem()
        setupLoadingPopover()
        observeMenuBarIconStyle()

        // ApolloController connects to port 4710 in its initializer. Defer
        // creating it until the Mixer Engine has started or been found.
        UABackendManager.shared.startBeforeConnection { [weak self] _ in
            guard let self else { return }
            self.backendStartupCompleted = true

            if let application = self.pendingTerminationReply {
                self.stopBackendAndReply(to: application)
            } else {
                let controller = ApolloController()
                self.apollo = controller
                KeyboardVolumeManager.shared.start(controller: controller)
                self.observeApolloForMenuBar()
                self.setupPopover(for: controller)
                self.refreshMenuBarIcon()
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem?.button else { return }

        button.image = currentStatusImage()
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.target = self
        button.action = #selector(togglePopover)
        button.setAccessibilityLabel("Apollo Remote")
        button.setAccessibilityHelp("Click to open volume controls")
    }

    private func setupLoadingPopover() {
        popover = NSPopover()
        popover?.delegate = self
        popover?.contentSize = NSSize(width: 280, height: 120)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(
            rootView: VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                    .tint(.white.opacity(0.9))
                Text("Starting Apollo Remote")
                    .font(.system(size: 12, weight: .semibold))
                Text("Preparing the audio engine…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 280, height: 120)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        )
        makePopoverTransparent(popover)
    }

    private func setupPopover(for controller: ApolloController) {
        let monitorPopover = NSPopover()
        monitorPopover.contentSize = NSSize(width: 300, height: 360)
        monitorPopover.behavior = .transient
        monitorPopover.animates = true
        monitorPopover.delegate = self
        let hostingController = NSHostingController(
            rootView: MonitorView(
                apollo: controller,
                onQuit: { NSApp.terminate(nil) }
            )
        )
        // Keep the popover pinned to the contentSize set below. Without this,
        // NSHostingController tracks SwiftUI's own "ideal" size and can grow
        // the popover to fit whichever settings tab has the most content
        // (Audio, with its two segmented pickers, was ballooning well past
        // the app's own frame).
        hostingController.sizingOptions = []
        monitorPopover.contentViewController = hostingController
        makePopoverTransparent(monitorPopover)
        popover = monitorPopover
    }

    /// Strip the default opaque popover chrome so SwiftUI materials can show the desktop.
    private func makePopoverTransparent(_ popover: NSPopover?) {
        guard let popover else { return }
        // Defer until the window exists (after first show).
        DispatchQueue.main.async {
            guard let window = popover.contentViewController?.view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.contentView?.wantsLayer = true
            window.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func observeApolloForMenuBar() {
        guard let apollo else { return }

        Publishers.CombineLatest3(apollo.$volumeTapered, apollo.$volume, apollo.$isConnected)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.refreshMenuBarIcon() }
            .store(in: &apolloCancellables)

        Publishers.CombineLatest3(apollo.$isMuted, apollo.$isDimmed, apollo.$isMono)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in self?.refreshMenuBarIcon() }
            .store(in: &apolloCancellables)

        Publishers.CombineLatest(apollo.$devices, apollo.$selectedDeviceId)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.refreshMenuBarIcon() }
            .store(in: &apolloCancellables)

        // Engine lifecycle tied to hardware presence
        Publishers.CombineLatest(apollo.$devices, apollo.$isConnected)
            .receive(on: RunLoop.main)
            .sink { [weak self] devices, connected in
                let anyOnline = connected && devices.contains(where: { $0.isOnline })
                if anyOnline {
                    UABackendManager.shared.cancelAutoQuitOnDisconnect()
                    UABackendManager.shared.ensureMixerRunningOnDeviceDetect()
                } else if connected {
                    // Connected to host but no online Apollo yet — wait, don't
                    // touch the Mixer Engine or Apollo Remote itself.
                    UABackendManager.shared.cancelAutoQuitOnDisconnect()
                } else {
                    // Fully offline: after the grace window, quit the UA apps,
                    // then Apollo Remote itself after that shutdown completes.
                    UABackendManager.shared.scheduleAutoQuitOnDisconnect { [weak self] in
                        self?.quitAppIfEnabled()
                    }
                }
            }
            .store(in: &apolloCancellables)
    }

    /// Quits Apollo Remote itself after the UA shutdown has completed.
    /// This lifecycle behavior is mandatory and has no user-facing toggle.
    private func quitAppIfEnabled() {
        NSApp.terminate(nil)
    }

    private func observeMenuBarIconStyle() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMenuBarIcon()
            KeyboardVolumeManager.shared.refresh()
        }
    }

    private var menuBarIconStyle: ApolloStatusIconStyle {
        let rawValue = UserDefaults.standard.string(forKey: "menuBarIconStyle")
            ?? ApolloStatusIconStyle.arcColor.rawValue
        return ApolloStatusIconStyle(rawValue: rawValue) ?? .arcColor
    }

    private func currentStatusImage() -> NSImage {
        ApolloArcIcon.image(
            fraction: CGFloat(apollo?.volumeTapered ?? 0),
            active: apollo?.isDeviceOnline ?? false,
            muted: apollo?.isMuted ?? false,
            dimmed: apollo?.isDimmed ?? false,
            mono: apollo?.isMono ?? false,
            style: menuBarIconStyle
        )
    }

    private func refreshMenuBarIcon() {
        guard let button = statusItem?.button else { return }
        button.image = currentStatusImage()
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown

        guard let apollo else {
            button.toolTip = "Apollo Remote · Starting"
            return
        }
        button.toolTip = apollo.isConnected
            ? "Apollo Remote · \(apollo.volumeDisplay) dB"
            : "Apollo Remote · Disconnected"
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            VolumeOverlayController.shared.setInterfaceOpen(true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            makePopoverTransparent(popover)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        VolumeOverlayController.shared.setInterfaceOpen(false)
    }

    func popoverWillShow(_ notification: Notification) {
        VolumeOverlayController.shared.setInterfaceOpen(true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard pendingTerminationReply == nil else { return .terminateLater }
        pendingTerminationReply = sender

        if backendStartupCompleted {
            stopBackendAndReply(to: sender)
        }
        return .terminateLater
    }

    private func stopBackendAndReply(to application: NSApplication) {
        // Tell the widget we're going away *now*, on a clean quit, rather than
        // relying solely on the heartbeat timing out up to 45s later — the widget
        // was previously left showing whatever "connected"/volume state happened
        // to be last written, indefinitely, after the app quit.
        sharedDefaults.set(false, forKey: "widgetConnected")
        sharedDefaults.set(Date().timeIntervalSince1970, forKey: "widgetLastUpdate")
        WidgetCenter.shared.reloadAllTimelines()

        UABackendManager.shared.stop {
            application.reply(toApplicationShouldTerminate: true)
        }
    }
}
