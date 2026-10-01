import AppKit
import CoreAudio
import Foundation

/// Intercepts the Mac volume-up, volume-down, and mute media keys when an
/// Apollo is the default output — no Fn, no ⌘, no other function keys.
///
/// Parsing follows the same rules as Chromium / volumeHUD / apollo-monitor:
/// convert the CGEvent to NSEvent, require subtype == 8
/// (NX_SUBTYPE_AUX_CONTROL_BUTTONS), then read NX key codes from data1.
/// Plain F8/F9/F10 keyDown events are ignored.
final class KeyboardVolumeManager {
    static let shared = KeyboardVolumeManager()

    private static let systemDefinedEventType = CGEventType(rawValue: 14)! // NX_SYSDEFINED

    // NX_KEYTYPE_* from IOKit/hidsystem/ev_keymap.h
    private static let nxSoundUp = 0
    private static let nxSoundDown = 1
    private static let nxMute = 7

    // NX_SUBTYPE_AUX_CONTROL_BUTTONS — media keys only
    private static let mediaKeySubtype: Int16 = 8

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private weak var controller: ApolloController?

    private var repeatCount = 0
    private var lastDownTime: CFAbsoluteTime = 0
    private var lastKey: Int = -1
    private var lastAcceptedStepTime: CFAbsoluteTime = 0
    private static let minStepInterval: CFAbsoluteTime = 0.05

    /// Latch so mute only fires once per physical press (down→up cycle).
    private var muteKeyHeld = false

    private var trustPollTimer: Timer?
    private var maintenanceTimer: Timer?
    private var defaultOutputIsApollo = false
    private var outputWatcherInstalled = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    private var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private init() {}

    // MARK: - Public API

    func start(controller: ApolloController) {
        self.controller = controller
        installOutputWatcherIfNeeded()
        installLifecycleObserversIfNeeded()
        refreshDefaultOutput()
        guard UserDefaults.standard.bool(forKey: "keyboardVolumeKeysEnabled") else { return }
        if AXIsProcessTrusted() {
            installIfPossible()
            startMaintenanceTimer()
        } else {
            requestAccessibility()
        }
    }

    func refresh() {
        refreshDefaultOutput()
        if UserDefaults.standard.bool(forKey: "keyboardVolumeKeysEnabled") {
            if AXIsProcessTrusted() {
                if tap == nil {
                    installIfPossible()
                } else if let tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                startMaintenanceTimer()
            } else {
                requestAccessibility()
            }
        } else {
            stop()
        }
    }

    func stop() {
        trustPollTimer?.invalidate()
        trustPollTimer = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        teardownTap()
        repeatCount = 0
        lastKey = -1
        muteKeyHeld = false
    }

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibility() {
        // Never ask macOS to prompt when permission is already granted.
        // This prevents duplicate startup dialogs, especially after relaunch.
        guard !AXIsProcessTrusted() else {
            trustPollTimer?.invalidate()
            trustPollTimer = nil
            return
        }

        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startTrustPolling()
    }

    // MARK: - Trust polling

    private func startTrustPolling() {
        guard trustPollTimer == nil else { return }
        var elapsed: TimeInterval = 0
        let interval: TimeInterval = 2.0
        trustPollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            elapsed += interval
            guard UserDefaults.standard.bool(forKey: "keyboardVolumeKeysEnabled") else {
                timer.invalidate()
                self.trustPollTimer = nil
                return
            }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.trustPollTimer = nil
                self.installIfPossible()
                self.startMaintenanceTimer()
            } else if elapsed >= 60 {
                timer.invalidate()
                self.trustPollTimer = nil
            }
        }
        if let trustPollTimer {
            RunLoop.main.add(trustPollTimer, forMode: .common)
        }
    }

    // MARK: - Tap lifecycle

    private func startMaintenanceTimer() {
        guard maintenanceTimer == nil else { return }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) { [weak self] _ in
            self?.reenableTapIfNeeded()
        }
        if let maintenanceTimer {
            RunLoop.main.add(maintenanceTimer, forMode: .common)
        }
    }

    private func reenableTapIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "keyboardVolumeKeysEnabled"),
              AXIsProcessTrusted() else { return }
        if tap == nil {
            installIfPossible()
        } else if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func recreateTap() {
        guard UserDefaults.standard.bool(forKey: "keyboardVolumeKeysEnabled"),
              AXIsProcessTrusted() else { return }
        teardownTap()
        installIfPossible()
    }

    private func installLifecycleObserversIfNeeded() {
        guard lifecycleObservers.isEmpty else { return }
        lifecycleObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.recreateTap() }
        )
        lifecycleObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in self?.recreateTap() }
        )
    }

    private func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
    }

    private func installIfPossible() {
        guard tap == nil, AXIsProcessTrusted() else { return }

        // Only system-defined events. Media keys are subtype 8; we filter that
        // inside the callback via NSEvent. No keyDown/keyUp mask — F8/F9/F10
        // as plain function keys must never reach us.
        let mask = CGEventMask(1 << Self.systemDefinedEventType.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<KeyboardVolumeManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(event: event, type: type)
        }

        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        tap = newTap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        if let runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: newTap, enable: true)
        }
    }

    // MARK: - Event handling

    private func handle(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap, AXIsProcessTrusted() {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == Self.systemDefinedEventType else {
            return Unmanaged.passUnretained(event)
        }
        guard UserDefaults.standard.bool(forKey: "keyboardVolumeKeysEnabled") else {
            return Unmanaged.passUnretained(event)
        }
        // Check live rather than trusting the cached `defaultOutputIsApollo`
        // flag: that flag only updates when CoreAudio fires a device-changed
        // notification, and on some Macs that notification lags (or is
        // coalesced) right around device changes. Reading it stale let a key
        // press slip through unswallowed and made the system's own volume
        // HUD flash up even while Apollo was already the default output.
        // This call is cheap (a couple of CoreAudio property reads) and only
        // runs on an actual key press, so doing it live is not a concern.
        guard let controller, controller.isConnected, isApolloDefaultOutput() else {
            return Unmanaged.passUnretained(event)
        }

        // Critical: read via NSEvent. CGEvent data1 fields are unreliable for
        // system-defined events; subtype must be 8 (media / aux control).
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == Self.mediaKeySubtype else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyFlags = data1 & 0x0000FFFF
        let keyState = (keyFlags & 0xFF00) >> 8
        // 0x0A = down, 0x0B = up, 0x0C = repeat (treat as down)
        let isDown = (keyState == 0x0A || keyState == 0x0C)

        // Strict allow-list: only volume up / volume down / mute.
        guard keyCode == Self.nxSoundUp
                || keyCode == Self.nxSoundDown
                || keyCode == Self.nxMute else {
            return Unmanaged.passUnretained(event)
        }

        // ---- Mute: one toggle per physical press. Hold does nothing. ----
        // Some keyboards re-fire 0x0A or only send 0x0C while held. Latch on
        // first down-like event; clear on key-up (0x0B). Nothing in between.
        if keyCode == Self.nxMute {
            let action = UserDefaults.standard.string(forKey: "keyboardMuteAction") ?? "mute"
            if action == "none" {
                return Unmanaged.passUnretained(event)
            }

            if keyState == 0x0B {
                // Key up — arm for the next press.
                muteKeyHeld = false
                return nil
            }

            // Down (0x0A) or repeat (0x0C): fire only if not already held.
            guard !muteKeyHeld else { return nil }
            muteKeyHeld = true

            if action == "dim" {
                controller.toggleDim()
            } else {
                controller.toggleMute()
            }
            showOverlay(controller)
            return nil
        }

        // ---- Volume up / down ----
        guard isDown else {
            // Swallow matching ups so the system never sees a half pair.
            return nil
        }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastAcceptedStepTime < Self.minStepInterval {
            return nil
        }

        if lastKey != keyCode || now - lastDownTime > 0.40 {
            repeatCount = 0
        } else {
            repeatCount += 1
        }
        lastKey = keyCode
        lastDownTime = now
        lastAcceptedStepTime = now

        // Map the user-facing dB step setting onto the Apollo's 1/54 tapered
        // detent grid (~1.8 dB per detent). This is what the on-screen slider
        // drives, so keys and slider stay in lockstep without fighting.
        let configuredStep = UserDefaults.standard.double(forKey: "volumeStep")
        let baseDB = configuredStep > 0 ? configuredStep : 3.0
        let baseDetents = max(1, Int((baseDB / 1.8).rounded()))
        let detents: Int
        switch repeatCount {
        case 0..<3: detents = baseDetents
        case 3..<8: detents = baseDetents + 1
        default:    detents = min(6, baseDetents + 2)
        }

        if keyCode == Self.nxSoundUp {
            controller.stepTapered(detents: detents)
        } else {
            controller.stepTapered(detents: -detents)
        }
        showOverlay(controller)
        return nil
    }

    private func showOverlay(_ controller: ApolloController) {
        guard UserDefaults.standard.bool(forKey: "volumeOverlayEnabled") else { return }
        DispatchQueue.main.async {
            VolumeOverlayController.shared.show(for: controller)
        }
    }

    // MARK: - Default-output watcher

    private func installOutputWatcherIfNeeded() {
        guard !outputWatcherInstalled else { return }
        outputWatcherInstalled = true
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in self?.refreshDefaultOutput() }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main
        ) { [weak self] _, _ in self?.refreshDefaultOutput() }
    }

    private func refreshDefaultOutput() {
        guard controller != nil else {
            defaultOutputIsApollo = false
            return
        }
        defaultOutputIsApollo = isApolloDefaultOutput()
    }

    private func isApolloDefaultOutput() -> Bool {
        guard let deviceID = defaultOutputDevice() else { return false }
        let manufacturer = audioDeviceString(deviceID, selector: kAudioObjectPropertyManufacturer)
        let defaultName = audioDeviceString(deviceID, selector: kAudioObjectPropertyName)
        if [manufacturer, defaultName]
            .compactMap({ $0 })
            .contains(where: {
                $0.localizedCaseInsensitiveContains("Universal Audio")
                    || $0.localizedCaseInsensitiveContains("Apollo")
            }) {
            return true
        }
        guard let controller, let defaultName else { return false }
        let name = controller.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return defaultName == name
            || defaultName.localizedCaseInsensitiveContains(name)
            || name.localizedCaseInsensitiveContains(defaultName)
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var address = defaultOutputAddress
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private func audioDeviceString(
        _ deviceID: AudioDeviceID,
        selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value as String : nil
    }
}
