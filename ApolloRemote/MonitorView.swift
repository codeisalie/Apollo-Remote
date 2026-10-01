import SwiftUI
import AppKit
import ServiceManagement
import CoreAudio

// MARK: - Slider Tuning Profiles

enum SliderTuningProfile: String, CaseIterable, Identifiable {
    case off = "Off"
    case softner = "Softner"
    case smooth = "Smooth"
    case pickup = "Slide Safety"

    var id: String { rawValue }

    /// Slide Safety = pickup-mode dragging. Shows a lock badge wherever it's referenced.
    var isSlideSafety: Bool { self == .pickup }

    var description: String {
        switch self {
        case .off:
            return "No tuning at all. Standard unassisted 1:1 tracking, identical feel to the native macOS slider."
        case .softner:
            return "Gentle direct tracking with a natural, low-latency feel."
        case .smooth:
            return "Softened spring interpolation for smooth, dampened level sweeps."
        case .pickup:
            return "Pickup-mode dragging — touching the slider never jumps the level. You have to move the cursor from wherever you grabbed it before volume follows. Prevents accidental jumps and speaker blowouts."
        }
    }
}

// MARK: - Slider Visual Styles

enum SliderVisualStyle: String, CaseIterable, Identifiable {
    case glow = "Glow"
    case system = "System"
    case thin = "Thin"
    case led = "LED"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .glow:
            return "Filled track with floating percentage badge (original look)."
        case .system:
            return "Native macOS slider control."
        case .thin:
            return "Slim capsule bar with a compact thumb."
        case .led:
            return "Segmented LED meter style."
        }
    }
}

// MARK: - Apollo Controller Sample Rate Extensions (local CoreAudio only — see setSampleRate)

extension ApolloController {
    
    /// Returns supported sample rates for Apollo hardware
    func getSupportedSampleRates() -> [Double] {
        guard let deviceID = getApolloAudioDeviceID() else { return [44100, 48000, 88200, 96000, 176400, 192000] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr else { return [44100, 48000, 88200, 96000, 176400, 192000] }
        
        let count = Int(dataSize) / MemoryLayout<AudioValueRange>.stride
        var ranges = [AudioValueRange](repeating: AudioValueRange(), count: count)
        
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &ranges) == noErr else { return [44100, 48000, 88200, 96000, 176400, 192000] }
        
        let rates = ranges.map { $0.mMinimum }.sorted()
        return rates.isEmpty ? [44100, 48000, 88200, 96000, 176400, 192000] : rates
    }

    /// Reads active sample rate via CoreAudio read-only inspection
    func getCurrentSampleRate() -> Double? {
        guard let deviceID = getApolloAudioDeviceID() else { return nil }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var sampleRate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &sampleRate)
        return status == noErr ? Double(sampleRate) : nil
    }

    /// Sets the nominal sample rate through CoreAudio — the same mechanism
    /// Audio MIDI Setup and UA Console itself use. There is no sample-rate
    /// control on UA Mixer Engine's TCP protocol (port 4710): that protocol
    /// only exposes the MONITOR output's level/mute/dim, nothing device-wide.
    /// Sample rate lives entirely in Core Audio, which only exists for a
    /// device that is physically attached to *this* Mac — so this only works
    /// when controlling a local Apollo, never a remote one over the network.
    @discardableResult
    func setSampleRate(_ rate: Double) -> Bool {
        guard let deviceID = getApolloAudioDeviceID() else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return false }
        var settable: DarwinBoolean = false
        if AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, !settable.boolValue {
            return false
        }
        var newRate = Float64(rate)
        let size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &newRate)
        return status == noErr
    }

    private func getApolloAudioDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.stride
        var devices = [AudioDeviceID](repeating: 0, count: count)

        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &devices) == noErr else { return nil }

        // Prefer the system default output when it is a UA device, otherwise
        // the first UA/Apollo device in the list. Matching only on "apollo" in
        // the product name missed drivers that publish as
        // "Universal Audio Thunderbolt".
        let defaultID = Self.coreAudioDefaultOutputDevice()
        if let defaultID, Self.isUniversalAudioDevice(defaultID) {
            return defaultID
        }

        for id in devices {
            if Self.isUniversalAudioDevice(id) {
                return id
            }
        }
        return nil
    }

    private static func coreAudioDefaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func isUniversalAudioDevice(_ deviceID: AudioDeviceID) -> Bool {
        let fields = [
            coreAudioString(deviceID, kAudioObjectPropertyManufacturer),
            coreAudioString(deviceID, kAudioObjectPropertyName),
        ].compactMap { $0 }
        return fields.contains {
            $0.localizedCaseInsensitiveContains("Universal Audio")
                || $0.localizedCaseInsensitiveContains("Apollo")
        }
    }

    private static func coreAudioString(_ deviceID: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
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

// MARK: - Main Monitor View

struct MonitorView: View {
    @ObservedObject var apollo: ApolloController
    @StateObject private var discovery = NetworkDiscovery()

    var onOpenSettings: () -> Void = {}
    var onOpenAbout: () -> Void = {}
    var onQuit: () -> Void = {}

    @State private var showSettings: Bool = false
    @State private var settingsTab: SettingsTab = .audio

    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("volumeStep") private var volumeStep = 3.0
    @AppStorage("menuBarIconStyle") private var menuBarIconStyleRaw = ApolloStatusIconStyle.arcColor.rawValue
    @AppStorage("keyboardVolumeKeysEnabled") private var keyboardVolumeKeysEnabled = true
    @AppStorage("keyboardMuteAction") private var keyboardMuteAction = "mute"
    @AppStorage("volumeOverlayEnabled") private var volumeOverlayEnabled = true
    @AppStorage("volumeHUDStyle") private var volumeHUDStyle = VolumeHUDStyle.compact.rawValue
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("sliderTuningProfile") private var sliderTuningProfileRaw = SliderTuningProfile.softner.rawValue
    @AppStorage("sliderVisualStyle") private var sliderVisualStyleRaw = SliderVisualStyle.glow.rawValue
    @AppStorage("volumeJumpLock") private var volumeJumpLock = true
    @AppStorage("showVolumePercentReadout") private var showVolumePercentReadout = true
    @AppStorage("showVolumeDBReadout") private var showVolumeDBReadout = true

    @State private var liveSampleRate: Double? = nil

    @State private var showManualAdd = false
    @State private var manualAddress = ""
    @State private var manualPort = "4710"

    @State private var isLaunchingMixerEngine = false

    @State private var isPulsePeak: Bool = false
    private let pulseDuration: Double = 3.5
    private let brightGreen = Color(red: 0.1, green: 1.0, blue: 0.2)

    private var activeTuningProfile: SliderTuningProfile {
        // Preserve existing preferences created by older builds.
        if sliderTuningProfileRaw == "Instant" || sliderTuningProfileRaw == "Precision" {
            return .softner
        }
        return SliderTuningProfile(rawValue: sliderTuningProfileRaw) ?? .softner
    }

    private var activeVisualStyle: SliderVisualStyle {
        SliderVisualStyle(rawValue: sliderVisualStyleRaw) ?? .glow
    }

    enum SettingsTab: String, CaseIterable, Identifiable {
        case audio = "Audio"
        case general = "General"
        case keyboard = "Keyboard"
        case connection = "Connection"
        case about = "About"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 4) {
            if showSettings {
                SettingsContainerView(
                    apollo: apollo,
                    discovery: discovery,
                    settingsTab: $settingsTab,
                    showSettings: $showSettings,
                    showManualAdd: $showManualAdd,
                    manualAddress: $manualAddress,
                    manualPort: $manualPort,
                    volumeStep: $volumeStep,
                    menuBarIconStyleRaw: $menuBarIconStyleRaw,
                    launchAtLogin: $launchAtLogin,
                    keyboardVolumeKeysEnabled: $keyboardVolumeKeysEnabled,
                    keyboardMuteAction: $keyboardMuteAction,
                    volumeOverlayEnabled: $volumeOverlayEnabled,
                    volumeHUDStyle: $volumeHUDStyle,
                    appLanguage: $appLanguage,
                    sliderTuningProfileRaw: $sliderTuningProfileRaw,
                    sliderVisualStyleRaw: $sliderVisualStyleRaw,
                    showVolumePercentReadout: $showVolumePercentReadout,
                    showVolumeDBReadout: $showVolumeDBReadout,
                    volumeJumpLock: $volumeJumpLock
                )
                .transition(.opacity)
            } else {
                if isSearchingForDevice {
                    connectionLoadingContent
                        .transition(.opacity)
                } else if apollo.isConnected {
                    connectedContent
                        .transition(.opacity)
                } else {
                    disconnectedContent
                        .transition(.opacity)
                }
            }

            Divider()
                .background(Color.white.opacity(0.12))
                .padding(.horizontal, 14)

            bottomBar
        }
        .padding(.vertical, 5)
        .frame(width: 316)
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)

                Rectangle()
                    .fill(Color.black.opacity(0.35))

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.12),
                                Color.white.opacity(0.01)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.3),
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
        .animation(.easeInOut(duration: 0.2), value: showSettings)
        .onAppear {
            discovery.startBrowsing()
        }
        .environment(\.locale, appLanguage == "system" ? .current : Locale(identifier: appLanguage))
    }

    private var shouldPulse: Bool {
        apollo.isDimmed && !apollo.isMuted
    }

    private var isSearchingForDevice: Bool {
        switch apollo.connectionState {
        case .connecting, .enumerating:
            return true
        default:
            return false
        }
    }

    private var connectionLoadingContent: some View {
        VStack(spacing: 12) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 54, height: 54)

                ProgressView()
                    .controlSize(.regular)
                    .tint(.white.opacity(0.9))
            }

            VStack(spacing: 4) {
                Text(apollo.connectionState == .enumerating ? "Searching for Apollo" : "Connecting to Apollo")
                    .font(.system(size: 13, weight: .semibold))

                Text(apollo.statusMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .frame(minHeight: 170)
    }

    private var connectedContent: some View {
        Group {
            if apollo.monitorStateReady {
                connectedMonitorContent
            } else {
                monitorSyncingContent
            }
        }
    }

    private var connectedMonitorContent: some View {
        VStack(spacing: 1) {
            // Live sample rate — small, secondary, updates while the popover is open
            if apollo.selectedHost.isLocalhost, let rate = liveSampleRate {
                Text(formatSampleRate(rate))
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 16)
                    .padding(.bottom, -4)
            }

            volumeSlider
                .padding(.top, 5)
            volumeReadout
                .frame(height: 13, alignment: .center)
                .offset(y: -3)
            controlButtons
                .padding(.top, 1)
        }
        .onAppear { refreshLiveSampleRate() }
        .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
            refreshLiveSampleRate()
        }
    }

    private var monitorSyncingContent: some View {
        VStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text("Reading Apollo…")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 62)
    }

    private func refreshLiveSampleRate() {
        liveSampleRate = apollo.getCurrentSampleRate()
    }

    /// Live percent / dB readout shown between the slider and the control
    /// buttons. Either half can be turned off independently in Settings ▸ Audio.
    @ViewBuilder
    private var volumeReadout: some View {
        if showVolumePercentReadout || showVolumeDBReadout {
            HStack(spacing: 4) {
                if showVolumePercentReadout {
                    Text("\(Int((apollo.volumeTapered * 100).rounded()))%")
                }
                if showVolumePercentReadout && showVolumeDBReadout {
                    Text("·")
                        .foregroundStyle(.tertiary)
                }
                if showVolumeDBReadout {
                    Text(apollo.volumeDisplay)
                }
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private func formatSampleRate(_ rate: Double) -> String {
        let khz = rate / 1000.0
        if khz == floor(khz) {
            return "\(Int(khz)) kHz"
        }
        return String(format: "%.1f kHz", khz)
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                // LED reflects device connection: green when online, off when offline.
                let deviceOnline = apollo.isConnected && apollo.isDeviceOnline
                Circle()
                    .fill(deviceOnline ? brightGreen : Color.white.opacity(0.18))
                    .frame(width: 8, height: 8)
                    .shadow(
                        color: deviceOnline ? brightGreen.opacity(0.9) : .clear,
                        radius: deviceOnline ? 6 : 0,
                        x: 0, y: 0
                    )

                if deviceOnline, !apollo.deviceName.isEmpty {
                    Text(apollo.deviceName.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .tracking(0.8)
                        .lineLimit(1)
                } else {
                    Text("HOST")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .tracking(1.0)

                    Text("offline")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(-2))
                        .padding(.leading, 1)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                GlassIconButton(icon: "arrow.triangle.2.circlepath", help: "Reconnect", action: apollo.reconnect)
                GlassIconButton(
                    icon: showSettings ? "slider.horizontal.3" : "gearshape.fill",
                    help: showSettings ? "Monitor" : "Settings",
                    action: {
                        showSettings.toggle()
                        onOpenSettings()
                    }
                )
                GlassIconButton(icon: "power", help: "Quit", action: onQuit)
            }
        }
        .padding(.horizontal, 14)
    }

    /// True while we're actively trying to reach Apollo — drives the rotating
    /// orange ring in place of the native macOS spinner.
    private var isReconnectingState: Bool {
        switch apollo.connectionState {
        case .connecting, .retrying, .enumerating: return true
        default: return false
        }
    }

    private var disconnectedContent: some View {
        VStack(spacing: 8) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.12))
                    .frame(width: 44, height: 44)

                if isReconnectingState {
                    RotatingRing()
                } else {
                    Image(systemName: disconnectedIconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.orange)
                        .shadow(color: .orange.opacity(0.5), radius: 8, x: 0, y: 0)
                }
            }

            VStack(spacing: 3) {
                Text(disconnectedTitle)
                    .font(.system(size: 12, weight: .semibold))

                Text(apollo.statusMessage)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 220)

                if !apollo.selectedHost.isLocalhost {
                    Text(apollo.selectedHost.displayName)
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
            }

            if case .retrying = apollo.connectionState {
                Button("Try Now", action: apollo.reconnect)
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.blue)
            } else if case .connecting = apollo.connectionState {
                EmptyView()
            } else if case .enumerating = apollo.connectionState {
                EmptyView()
            } else {
                Button("Connect", action: apollo.reconnect)
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.2))
                    .controlSize(.small)
            }

            Button(action: launchMixerEngineManually) {
                HStack(spacing: 4) {
                    if isLaunchingMixerEngine {
                        ProgressView().controlSize(.mini)
                    }
                    Text(isLaunchingMixerEngine ? "Launching…" : "Launch UA Mixer Engine")
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .disabled(isLaunchingMixerEngine)
            .padding(.top, 2)

            Spacer()
        }
        .frame(minHeight: 150)
    }

    /// Manually boots UA Mixer Engine — useful after Apollo Remote auto-quit
    /// (see the 5s offline watchdog) or if the engine died on its own.
    private func launchMixerEngineManually() {
        isLaunchingMixerEngine = true
        UABackendManager.shared.manualLaunchMixerEngine { started in
            isLaunchingMixerEngine = false
            if started {
                apollo.reconnect()
            }
        }
    }

    private var disconnectedTitle: String {
        switch apollo.connectionState {
        case .connecting, .enumerating: return "Connecting…"
        case .retrying: return "Reconnecting…"
        default: return "Not Connected"
        }
    }

    private var disconnectedIconName: String {
        switch apollo.connectionState {
        case .connecting, .retrying, .enumerating: return "arrow.triangle.2.circlepath"
        default: return "bolt.horizontal.circle"
        }
    }

    private var sliderTrackColor: Color {
        if apollo.isMuted {
            return .red
        } else if apollo.isMono {
            return .orange
        } else {
            return brightGreen
        }
    }

    private var isAtZero: Bool {
        apollo.volume <= 0.001
    }

    private var volumeSlider: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let trackWidth = geometry.size.width
                let trackHeight: CGFloat = activeVisualStyle == .thin ? 12 : (activeVisualStyle == .led ? 20 : 20)

                ZStack(alignment: .leading) {
                    switch activeVisualStyle {
                    case .system:
                        Slider(
                            value: Binding(
                                get: { apollo.volumeTapered * 100.0 },
                                set: { apollo.setTaperedPercent($0) }
                            ),
                            in: 0...100
                        )
                        .controlSize(.regular)
                        .frame(width: trackWidth, height: trackHeight)

                    case .glow:
                        glowSlider(trackWidth: trackWidth, trackHeight: trackHeight)

                    case .thin:
                        thinSlider(trackWidth: trackWidth, trackHeight: trackHeight)

                    case .led:
                        ledSlider(trackWidth: trackWidth, trackHeight: trackHeight)
                    }

                    // One interaction layer sits above every visual style.
                    // This keeps click-to-jump / jump-lock behavior identical
                    // for System, Glow, Thin, and LED sliders.
                    ScrollAndDragInterceptView(
                            tuningProfile: activeTuningProfile,
                            onScroll: { delta, isPrecise in
                                let currentLinear = apollo.volumeTapered * 100.0
                                let sensitivity: Double = (activeTuningProfile == .off)
                                    ? (isPrecise ? 0.12 : 1.0)
                                    : (isPrecise ? 0.08 : 1.5)
                                let newLinear = max(0, min(100, currentLinear + (delta * sensitivity)))
                                apollo.setTaperedPercent(newLinear)
                            },
                            onDrag: { rawLinearVal in
                                apollo.setTaperedPercent(rawLinearVal)
                            },
                            currentPercent: { apollo.volumeTapered * 100.0 },
                            knobWidth: activeVisualStyle == .glow ? 44 : (activeVisualStyle == .thin ? 18 : 20),
                            jumpLockEnabled: volumeJumpLock
                        )
                        .frame(width: trackWidth, height: trackHeight)
                }
                .animation(
                    activeTuningProfile == .smooth ? .interactiveSpring(response: 0.22, dampingFraction: 0.82) : nil,
                    value: apollo.volumeTapered
                )
                .opacity((apollo.isDimmed && !apollo.isMuted) ? 0.85 : 1.0)
                .animation(.easeOut(duration: 0.1), value: apollo.isDimmed)
            }
            .frame(height: activeVisualStyle == .thin ? 12 : (activeVisualStyle == .led ? 20 : 20))

            HStack {
                Text("-\u{221E}")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)

                Spacer()

                Text("0 dB")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Slider Visual Styles

    @ViewBuilder
    private func glowSlider(trackWidth: CGFloat, trackHeight: CGFloat) -> some View {
        let knobWidth: CGFloat = 44
        let knobHeight: CGFloat = 20
        let percentage = CGFloat(max(0, min(1, apollo.volumeTapered)))
        let travel = max(0, trackWidth - knobWidth)
        let knobX = travel * percentage

        ZStack(alignment: .leading) {
            // Recessed track — clean, shallow and fully contained.
            RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                .fill(Color.black.opacity(0.34))
                .overlay(
                    RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
                .frame(width: trackWidth, height: trackHeight)

            if !isAtZero {
                RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [sliderTrackColor.opacity(0.62), sliderTrackColor.opacity(0.96)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: max(trackHeight, knobX + knobWidth / 2), height: trackHeight)
                    .clipShape(RoundedRectangle(cornerRadius: trackHeight / 2, style: .continuous))
                    .shadow(color: sliderTrackColor.opacity(0.28), radius: 4, y: 1)
            }

            // Floating thumb sits above the track so its edge and shadow never get clipped.
            RoundedRectangle(cornerRadius: knobHeight / 2, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.30), Color.white.opacity(0.12)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .background(
                    RoundedRectangle(cornerRadius: knobHeight / 2, style: .continuous)
                        .fill(.ultraThinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: knobHeight / 2, style: .continuous)
                        .stroke(Color.white.opacity(0.38), lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: knobHeight / 2, style: .continuous)
                        .stroke(sliderTrackColor.opacity(0.32), lineWidth: 1)
                        .padding(1)
                )
                .shadow(color: .black.opacity(0.34), radius: 4, y: 1)
                .shadow(color: sliderTrackColor.opacity(0.24), radius: 5)
                .frame(width: knobWidth, height: knobHeight)
                .overlay(
                    Text("\(Int((apollo.volumeTapered * 100).rounded()))%")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.95))
                )
                .offset(x: knobX)
        }
        .frame(height: knobHeight)
    }

    @ViewBuilder
    private func thinSlider(trackWidth: CGFloat, trackHeight: CGFloat) -> some View {
        let thumbW: CGFloat = 18
        let percentage = CGFloat(max(0, min(1, apollo.volumeTapered)))
        let thumbX = (trackWidth - thumbW) * percentage

        Capsule()
            .fill(Color.black.opacity(0.35))
            .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            .frame(width: trackWidth, height: 6)
            .frame(height: trackHeight)

        Capsule()
            .fill(sliderTrackColor.opacity(isAtZero ? 0 : 0.9))
            .frame(width: max(6, thumbX + thumbW / 2), height: 6)
            .frame(height: trackHeight, alignment: .leading)
            .clipped()

        Circle()
            .fill(.ultraThinMaterial)
            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
            .frame(width: thumbW, height: thumbW)
            .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
            .offset(x: thumbX)
    }

    @ViewBuilder
    private func ledSlider(trackWidth: CGFloat, trackHeight: CGFloat) -> some View {
        let segments = 24
        let gap: CGFloat = 2
        let segW = max(2, (trackWidth - gap * CGFloat(segments - 1)) / CGFloat(segments))
        let lit = Int(round(max(0, min(1, apollo.volumeTapered)) * Double(segments)))

        HStack(spacing: gap) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(i < lit ? sliderTrackColor.opacity(apollo.isMuted ? 0.7 : 0.95) : Color.white.opacity(0.08))
                    .frame(width: segW, height: trackHeight - 4)
            }
        }
        .frame(width: trackWidth, height: trackHeight)
        .clipped()
    }

    private var controlButtons: some View {
        HStack(spacing: 6) {
            GlassControlButton(
                iconName: apollo.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                label: "Mute",
                isActive: apollo.isMuted,
                activeColor: .red,
                action: apollo.toggleMute
            )

            GlassControlButton(
                label: "Mono",
                isActive: apollo.isMono,
                activeColor: .orange,
                action: apollo.toggleMono,
                customView: AnyView(IntersectingCirclesView(isActive: apollo.isMono))
            )

            GlassControlButton(
                iconName: "speaker.minus.fill",
                label: apollo.isDimmed ? "Dim -17" : "Dim",
                isActive: apollo.isDimmed,
                activeColor: .orange,
                action: apollo.toggleDim
            )
        }
        .padding(.horizontal, 14)
    }
}

// MARK: - Settings Container View

struct SettingsContainerView: View {
    @ObservedObject var apollo: ApolloController
    @ObservedObject var discovery: NetworkDiscovery
    @Binding var settingsTab: MonitorView.SettingsTab
    @Binding var showSettings: Bool
    @Binding var showManualAdd: Bool
    @Binding var manualAddress: String
    @Binding var manualPort: String
    @Binding var volumeStep: Double
    @Binding var menuBarIconStyleRaw: String
    @Binding var launchAtLogin: Bool
    @Binding var keyboardVolumeKeysEnabled: Bool
    @Binding var keyboardMuteAction: String
    @Binding var volumeOverlayEnabled: Bool
    @Binding var volumeHUDStyle: String
    @Binding var appLanguage: String
    @Binding var sliderTuningProfileRaw: String
    @Binding var sliderVisualStyleRaw: String
    @Binding var showVolumePercentReadout: Bool
    @Binding var showVolumeDBReadout: Bool
    @Binding var volumeJumpLock: Bool

    @State private var currentSampleRate: Double = 48000.0
    @State private var availableSampleRates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]

    private let brightGreen = Color(red: 0.1, green: 1.0, blue: 0.2)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(action: { showSettings = false }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("Monitor")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Preferences")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)

                Spacer()

                Color.clear.frame(width: 50, height: 1)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity)

            HStack(spacing: 2) {
                ForEach(MonitorView.SettingsTab.allCases) { tab in
                    Button {
                        settingsTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.system(size: 9, weight: .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .foregroundStyle(settingsTab == tab ? .white : .secondary)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(settingsTab == tab ? Color.accentColor : Color.white.opacity(0.06))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 10) {
                    switch settingsTab {
                    case .audio:
                        audioSettingsTab
                    case .general:
                        generalSettingsTab
                    case .keyboard:
                        keyboardSettingsTab
                    case .connection:
                        connectionSettingsTab
                    case .about:
                        aboutSettingsTab
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .frame(width: 316, alignment: .leading)
            }
            .frame(width: 316, height: 245, alignment: .top)
            .clipped()
        }
        .frame(width: 316, height: 300, alignment: .topLeading)
        .clipped()
        .onAppear {
            if let activeRate = apollo.getCurrentSampleRate() {
                self.currentSampleRate = activeRate
            }
            let rates = apollo.getSupportedSampleRates()
            if !rates.isEmpty {
                self.availableSampleRates = rates
            }
        }
    }

    // MARK: - Subviews

    private var audioSettingsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Sample rate
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sample Rate")
                        .font(.system(size: 11, weight: .semibold))

                    Spacer()

                    if apollo.selectedHost.isLocalhost {
                        Picker("", selection: Binding(
                            get: { currentSampleRate },
                            set: { newRate in
                                let previousRate = currentSampleRate
                                currentSampleRate = newRate
                                if !apollo.setSampleRate(newRate) {
                                    currentSampleRate = previousRate
                                }
                            }
                        )) {
                            ForEach(availableSampleRates, id: \.self) { rate in
                                Text("\(Int(rate / 1000.0)) kHz (\(Int(rate)) Hz)")
                                    .tag(rate)
                            }
                        }
                        .font(.system(size: 10))
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 170, alignment: .trailing)
                    } else {
                        Text("Local Mac only")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                if !apollo.selectedHost.isLocalhost {
                    Text("Sample rate is set through Core Audio on the Mac the Apollo is physically connected to.")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .glassPanel(cornerRadius: 12)

            // Device — compact formal card with the device name at left and selector at right.
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(apollo.isDeviceOnline ? brightGreen : Color.white.opacity(0.18))
                        .frame(width: 7, height: 7)
                        .shadow(color: apollo.isDeviceOnline ? brightGreen.opacity(0.8) : .clear, radius: 4)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Device")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(apollo.deviceName.isEmpty ? "Not selected" : apollo.deviceName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                devicePicker
                    .frame(width: 178, alignment: .trailing)
            }
            .padding(10)
            .glassPanel(cornerRadius: 11)

            // Volume Readout
            HStack(spacing: 14) {
                Text("Volume Readout")
                    .font(.system(size: 10.5, weight: .semibold))
                    .fixedSize()
                Spacer(minLength: 4)
                Toggle("Percent", isOn: $showVolumePercentReadout)
                    .font(.system(size: 9.5))
                    .fixedSize()
                Toggle("dB", isOn: $showVolumeDBReadout)
                    .font(.system(size: 9.5))
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .glassPanel(cornerRadius: 11)

        }
    }

    private var generalSettingsTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Slider Style belongs with the app-wide presentation controls.
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Slider Style")
                        .font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    Picker("", selection: $sliderVisualStyleRaw) {
                        ForEach(SliderVisualStyle.allCases) { style in
                            Text(style.rawValue).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .font(.system(size: 9.5))
                }

                if let style = SliderVisualStyle(rawValue: sliderVisualStyleRaw) {
                    Text(style.description)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .padding(9)
            .glassPanel(cornerRadius: 11)

            HStack(spacing: 8) {
                Image(systemName: volumeJumpLock ? "lock.fill" : "lock.open")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(volumeJumpLock ? .orange : .secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Volume Jump Lock")
                        .font(.system(size: 10.5, weight: .semibold))
                    Text(volumeJumpLock ? "Drag from the current level without jumping." : "Click anywhere to jump directly to that level.")
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $volumeJumpLock)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(9)
            .glassPanel(cornerRadius: 11)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Slider Response Tuning")
                        .font(.system(size: 10.5, weight: .semibold))
                    Spacer()
                    Picker("", selection: $sliderTuningProfileRaw) {
                        ForEach(SliderTuningProfile.allCases.filter { $0 != .pickup }) { profile in
                            Text(profile.rawValue).tag(profile.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .font(.system(size: 9.5))
                }
                if let profile = SliderTuningProfile(rawValue: sliderTuningProfileRaw), profile != .pickup {
                    Text(profile.description)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(9)
            .glassPanel(cornerRadius: 11)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Menu Bar")
                        .font(.system(size: 10.5, weight: .semibold))
                        .fixedSize()
                    Spacer()
                    Picker("", selection: $menuBarIconStyleRaw) {
                        ForEach(ApolloStatusIconStyle.allCases, id: \.rawValue) { style in
                            Text(style.rawValue).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .font(.system(size: 9.5))
                }

                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .font(.system(size: 9.5))
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .glassPanel(cornerRadius: 10)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Toggle("Show volume HUD overlay", isOn: $volumeOverlayEnabled)
                        .font(.system(size: 9.5, weight: .medium))
                        .onChange(of: volumeOverlayEnabled) { _, enabled in
                            if !enabled {
                                VolumeOverlayController.shared.dismiss()
                            }
                        }
                    Spacer(minLength: 6)
                    Picker("HUD Style", selection: $volumeHUDStyle) {
                        ForEach(VolumeHUDStyle.allCases) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    .labelsHidden()
                    .font(.system(size: 9))
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 104, alignment: .trailing)
                    .disabled(!volumeOverlayEnabled)
                }

                Text("On-screen pill while you adjust the monitor level.")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)

            }
            .padding(10)
            .glassPanel(cornerRadius: 12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Language")
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    Picker("", selection: $appLanguage) {
                        Text("🌐  System Default").tag("system")
                        Text("🇺🇸  English").tag("en")
                        Text("🇪🇸  Español").tag("es")
                        Text("🇫🇷  Français").tag("fr")
                        Text("🇩🇪  Deutsch").tag("de")
                        Text("🇯🇵  日本語").tag("ja")
                        Text("🇰🇷  한국어").tag("ko")
                        Text("🇨🇳  中文").tag("zh-Hans")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .font(.system(size: 9.5))
                }

                Text("Language preference is saved for the app interface.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .glassPanel(cornerRadius: 12)

        }
    }

    private var keyboardSettingsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions")
                    .font(.system(size: 11, weight: .semibold))

                permissionRow(
                    title: "Device Control & Data Access",
                    isGranted: KeyboardVolumeManager.shared.isAccessibilityTrusted,
                    actionTitle: KeyboardVolumeManager.shared.isAccessibilityTrusted ? "Open Settings" : "Authorize…",
                    action: {
                        if KeyboardVolumeManager.shared.isAccessibilityTrusted {
                            openSystemSettings("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
                        } else {
                            KeyboardVolumeManager.shared.requestAccessibility()
                        }
                    }
                )

                Divider().background(Color.white.opacity(0.08))

                permissionRow(
                    title: "Local Network",
                    isGranted: apollo.isConnected,
                    actionTitle: "Open Settings",
                    action: {
                        openSystemSettings("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork")
                    }
                )

                Text("Apollo Remote uses the local network to find and communicate with your UA Console / Apollo. macOS controls this approval in Privacy & Security → Local Network.")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .glassPanel(cornerRadius: 12)

            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard Settings")
                    .font(.system(size: 11, weight: .semibold))

                Toggle("Use Mac volume keys", isOn: $keyboardVolumeKeysEnabled)
                    .font(.system(size: 10))
                    .onChange(of: keyboardVolumeKeysEnabled) { _, _ in
                        KeyboardVolumeManager.shared.refresh()
                    }

                // Mute action sits directly under the master toggle so the
                // relationship is obvious.
                Picker("Mute key action", selection: $keyboardMuteAction) {
                    Text("Mute").tag("mute")
                    Text("Dim").tag("dim")
                    Text("Pass through").tag("none")
                }
                .font(.system(size: 10))
                .controlSize(.small)
                .disabled(!keyboardVolumeKeysEnabled)

                HStack {
                    Text("Volume key step")
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    Text("\(Int(volumeStep)) dB")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Slider(value: $volumeStep, in: 1...10, step: 1)
                    .controlSize(.small)
                    .disabled(!keyboardVolumeKeysEnabled)
            }
            .padding(10)
            .glassPanel(cornerRadius: 12)

            VStack(alignment: .leading, spacing: 6) {
                Text("Key Mappings")
                    .font(.system(size: 11, weight: .semibold))

                Text("The Mac volume and mute keys work on their own — no Fn, no ⌘. They drive the Apollo and replace Apple's HUD while this device is the default output. Held volume keys accelerate from 1× to 3×. Mute toggles once per press (holding does not re-toggle).")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .glassPanel(cornerRadius: 12)
        }
    }

    private func openSystemSettings(_ rawURL: String) {
        guard let url = URL(string: rawURL) else { return }
        NSWorkspace.shared.open(url)
    }

    private func permissionRow(title: String, isGranted: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isGranted ? brightGreen : .red)

            Text(title)
                .font(.system(size: 10, weight: .medium))

            Spacer()

            if isGranted {
                Text("Granted")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(brightGreen)
            } else {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(.blue)
            }
        }
    }

    private var connectionSettingsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("System & Console Diagnostics")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button(action: {
                        apollo.reconnect()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                            Text("Refresh")
                                .font(.system(size: 9, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                VStack(spacing: 6) {
                    diagnosticRow(
                        title: "UA Console Service",
                        isOk: apollo.connectionState != .disconnected,
                        statusText: apollo.connectionState == .connected ? "Active" : apollo.statusMessage
                    )

                    Divider().background(Color.white.opacity(0.08))

                    diagnosticRow(
                        title: "Host Network API",
                        isOk: apollo.isConnected,
                        statusText: apollo.isConnected ? "Port 4710 Linked" : "Unreachable"
                    )

                    Divider().background(Color.white.opacity(0.08))

                    diagnosticRow(
                        title: "Hardware Link",
                        isOk: !apollo.devices.isEmpty && apollo.isConnected,
                        statusText: apollo.devices.isEmpty ? "No Apollo Detected" : apollo.deviceName
                    )
                }

                Text("Ensure UA Console app is running and 'Allow Local Network Access' is authorized.")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
            .padding(10)
            .glassPanel(cornerRadius: 12)

            VStack(spacing: 0) {
                connectionStatusBanner
                Divider().background(Color.white.opacity(0.1))
                discoveredHostsHeader
                Divider().background(Color.white.opacity(0.1))
                hostList
            }
            .glassPanel(cornerRadius: 14)
        }
    }

    private func diagnosticRow(title: String, isOk: Bool, statusText: String) -> some View {
        HStack {
            Image(systemName: isOk ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(isOk ? brightGreen : .red)

            Text(title)
                .font(.system(size: 10, weight: .medium))

            Spacer()

            Text(statusText)
                .font(.system(size: 9, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSettingsTab: some View {
        VStack(alignment: .center, spacing: 8) {
            Image("AboutIcon")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.top, 2)

            Text("Apollo Remote")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)

            Text("Version \(appVersion) (Build \(buildNumber))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 2)

            Text("A sleek companion app for monitoring and controlling your audio hardware interface seamlessly.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 4)
        }
        .padding(12)
        .glassPanel(cornerRadius: 14)
    }

    // MARK: - Connection Sub-Components

    private var connectionStatusBanner: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(apollo.isConnected ? "Connected" : "Not Connected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)

                Text(apollo.statusMessage)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if !apollo.isConnected {
                Button("Reconnect") {
                    apollo.reconnect()
                }
                .controlSize(.mini)
            }
        }
        .padding(8)
        .background(
            LinearGradient(
                colors: [connectionColor.opacity(0.18), connectionColor.opacity(0.08)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var discoveredHostsHeader: some View {
        HStack {
            Text("Available Hosts")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer()

            if discovery.isSearching {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Scanning…").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            } else {
                Button(action: { discovery.startBrowsing() }) {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 8))
                        Text("Scan").font(.system(size: 9))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var hostList: some View {
        VStack(spacing: 0) {
            hostRow(UAHost.localhost)
            Divider().background(Color.white.opacity(0.08))

            let remoteHosts = allRemoteHosts
            if remoteHosts.isEmpty {
                emptyDiscoveryRow
            } else {
                ForEach(Array(remoteHosts.enumerated()), id: \.element.id) { index, host in
                    hostRow(host)
                    if index < remoteHosts.count - 1 {
                        Divider().background(Color.white.opacity(0.08)).padding(.leading, 30)
                    }
                }
            }

            Divider().background(Color.white.opacity(0.08))
            manualAddRow
        }
    }

    private func hostRow(_ host: UAHost) -> some View {
        let isSelected = apollo.selectedHost.id == host.id

        return Button(action: {
            if !isSelected { apollo.connectToHost(host) }
        }) {
            HStack(spacing: 8) {
                Image(systemName: host.isLocalhost ? "desktopcomputer" : "network")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    Text(host.displayName)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(.white)

                    Text(host.isLocalhost ? "127.0.0.1" : host.address)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.blue)
                } else if !host.isLocalhost && host.isManual {
                    Button(action: { apollo.removeHost(host) }) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.blue.opacity(0.15) : Color.clear)
    }

    private var emptyDiscoveryRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 16)

            Text(discovery.isSearching ? "Looking for UA Console…" : "No remote hosts found")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var manualAddRow: some View {
        VStack(spacing: 0) {
            Button(action: { withAnimation { showManualAdd.toggle() } }) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.blue)
                        .frame(width: 16)

                    Text("Add host manually…")
                        .font(.system(size: 10))
                        .foregroundStyle(.blue)

                    Spacer()

                    Image(systemName: showManualAdd ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showManualAdd {
                Divider().background(Color.white.opacity(0.08))
                HStack(spacing: 6) {
                    TextField("IP address", text: $manualAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))

                    TextField("Port", text: $manualPort)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .frame(width: 50)

                    Button("Add") {
                        let port = UInt16(manualPort) ?? 4710
                        let host = UAHost(address: manualAddress, port: port, displayName: manualAddress, isManual: true)
                        apollo.addHost(host)
                        apollo.connectToHost(host)
                        manualAddress = ""
                        manualPort = "4710"
                        withAnimation { showManualAdd = false }
                    }
                    .controlSize(.mini)
                    .disabled(manualAddress.isEmpty)
                }
                .padding(6)
            }
        }
    }

    private var devicePicker: some View {
        Picker("", selection: Binding(
            get: { apollo.selectedDeviceId },
            set: { apollo.selectDevice($0) }
        )) {
            ForEach(apollo.devices) { device in
                HStack {
                    Text(device.name)
                    if !device.isOnline {
                        Text("(offline)").foregroundStyle(.secondary).font(.caption2)
                    }
                }
                .tag(device.id)
            }
        }
        .labelsHidden()
        .font(.system(size: 10.5))
        .disabled(apollo.devices.isEmpty)
    }

    private var outputPicker: some View {
        Picker("Output", selection: Binding(
            get: { apollo.selectedOutputId },
            set: { apollo.selectOutput($0) }
        )) {
            ForEach(apollo.outputs) { output in
                Text(output.name).tag(output.id)
            }
        }
        .font(.system(size: 11))
    }

    private var allRemoteHosts: [UAHost] {
        var hosts = apollo.knownHosts.filter { !$0.isLocalhost }
        for host in discovery.discoveredHosts {
            if !hosts.contains(where: { $0.address == host.address }) {
                hosts.append(host)
            }
        }
        return hosts
    }

    private var connectionColor: Color {
        switch apollo.connectionState {
        case .connected: brightGreen
        case .connecting, .retrying, .enumerating: .orange
        case .disconnected: .red
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Failed to update launch at login: \(error)")
        }
    }
}

// MARK: - Custom Intersecting Circles Shape Icon

struct IntersectingCirclesView: View {
    var isActive: Bool

    var body: some View {
        ZStack {
            Circle()
                .stroke(isActive ? Color.orange : Color.white, lineWidth: 1.8)
                .frame(width: 13, height: 13)
                .offset(x: -3.5)

            Circle()
                .stroke(isActive ? Color.orange : Color.white, lineWidth: 1.8)
                .frame(width: 13, height: 13)
                .offset(x: 3.5)
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Control Button Component

struct GlassControlButton: View {
    var iconName: String? = nil
    let label: String
    let isActive: Bool
    let activeColor: Color
    let action: () -> Void
    var customView: AnyView? = nil

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isActive ? activeColor.opacity(0.25) : Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(
                                    isActive ? activeColor.opacity(0.6) : Color.white.opacity(0.1),
                                    lineWidth: 1
                                )
                        )
                        .frame(maxWidth: .infinity, minHeight: 39, maxHeight: 39)
                        .shadow(color: isActive ? activeColor.opacity(0.3) : .clear, radius: 8, x: 0, y: 2)

                    if let customView = customView {
                        customView
                    } else if let iconName = iconName {
                        Image(systemName: iconName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isActive ? activeColor : .white)
                    }
                }

                Text(label)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(isActive ? activeColor : .secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AppKit Scroll & Drag Interceptor

struct ScrollAndDragInterceptView: NSViewRepresentable {
    var tuningProfile: SliderTuningProfile = .softner
    var onScroll: (Double, Bool) -> Void
    var onDrag: (Double) -> Void
    /// Read the controller's *current* percent at the moment of mouseDown.
    /// Used whenever jump-lock behavior is active (`jumpLockEnabled`, or the
    /// legacy `.pickup` tuning profile) so the drag is measured relative to
    /// wherever the slider already is, not the touch point.
    var currentPercent: () -> Double = { 0 }
    var knobWidth: CGFloat = 0
    /// Volume Jump Lock — its own on/off setting, independent of the Slider
    /// Response Tuning Profile. When on, pressing down anywhere on the track
    /// (not just the visible knob) never snaps the level to that point;
    /// volume only moves once the cursor actually travels, same distance,
    /// from wherever it was pressed. Overrides the tuning profile's own
    /// touch-down behavior; scroll-wheel behavior is unaffected.
    var jumpLockEnabled: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = InterceptView()
        view.tuningProfile = tuningProfile
        view.jumpLockEnabled = jumpLockEnabled
        view.onScroll = onScroll
        view.onDrag = onDrag
        view.currentPercent = currentPercent
        view.knobWidth = knobWidth
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? InterceptView {
            view.tuningProfile = tuningProfile
            view.jumpLockEnabled = jumpLockEnabled
            view.onScroll = onScroll
            view.onDrag = onDrag
            view.currentPercent = currentPercent
            view.knobWidth = knobWidth
        }
    }

    class InterceptView: NSView {
        var tuningProfile: SliderTuningProfile = .softner
        var jumpLockEnabled: Bool = false
        var onScroll: ((Double, Bool) -> Void)?
        var onDrag: ((Double) -> Void)?
        var currentPercent: (() -> Double)?
        var knobWidth: CGFloat = 0

        private var isDragging = false
        private var lastX: CGFloat = 0.0

        // Jump-lock bookkeeping (Volume Jump Lock, and the legacy `.pickup`
        // tuning profile it grew out of): where the drag started, both in
        // screen space and in the volume that was active at that moment.
        private var pickupOriginX: CGFloat = 0.0
        private var pickupBaselinePercent: Double = 0.0

        /// True whenever touch-down/drag should use jump-lock (relative)
        /// positioning instead of the tuning profile's own behavior.
        private var usesJumpLock: Bool {
            jumpLockEnabled || tuningProfile == .pickup
        }

        override func scrollWheel(with event: NSEvent) {
            if event.phase == .ended || event.momentumPhase != .init(rawValue: 0) {
                return
            }

            let rawDelta = abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
            if rawDelta != 0 {
                let multiplier: Double = event.isDirectionInvertedFromDevice ? -1.0 : 1.0
                var finalDelta = Double(rawDelta) * multiplier

                switch tuningProfile {
                case .off, .softner, .pickup:
                    break
                case .smooth:
                    finalDelta *= 0.65
                }

                onScroll?(finalDelta, event.hasPreciseScrollingDeltas)
            }
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            lastX = point.x
            isDragging = true

            let width = bounds.width
            guard width > 0 else { return }

            if usesJumpLock {
                // Jump Lock ON: grabbing anywhere establishes a pickup point.
                // The hardware level stays exactly where it was until the
                // cursor moves, then follows the cursor by relative distance.
                pickupOriginX = point.x
                pickupBaselinePercent = currentPercent?() ?? 0
                return
            }

            // Jump Lock OFF: a click anywhere on the track immediately jumps
            // the level to that position, just like a normal slider. This is
            // deliberately independent of the visual style and tuning profile.
            let percent = max(0, min(100, (point.x / width) * 100.0))
            onDrag?(Double(percent))
            lastX = point.x
        }

        override func mouseDragged(with event: NSEvent) {
            guard isDragging else { return }

            let point = convert(event.locationInWindow, from: nil)
            let width = bounds.width
            guard width > 0 else { return }

            guard !usesJumpLock else {
                // Pure 1:1 relative motion from the pickup point — the level
                // change exactly matches how far the cursor has moved since
                // mouseDown, regardless of where in the track the click landed.
                let deltaX = point.x - pickupOriginX
                let percentDelta = (deltaX / width) * 100.0
                let newPercent = max(0, min(100, pickupBaselinePercent + Double(percentDelta)))
                onDrag?(newPercent)
                lastX = point.x
                return
            }

            switch tuningProfile {
            case .off, .softner:
                let percent = max(0, min(100, (point.x / width) * 100.0))
                onDrag?(Double(percent))
            case .smooth:
                let deltaX = point.x - lastX
                let basePercentDelta = (deltaX / width) * 100.0
                let absDelta = abs(deltaX)
                let speedMultiplier = max(1.0, min(4.5, Double(absDelta) * 0.35))
                onScroll?(Double(basePercentDelta) * speedMultiplier, true)
            case .pickup:
                break // handled by usesJumpLock above
            }
            lastX = point.x
        }

        override func mouseUp(with event: NSEvent) {
            isDragging = false
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            return self
        }
    }
}

/// Continuously rotating orange arc shown on the reconnecting screen in
/// place of the native macOS `ProgressView` spinner.
struct RotatingRing: View {
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.72)
            .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 26, height: 26)
            .rotationEffect(.degrees(rotation))
            .shadow(color: .orange.opacity(0.5), radius: 6, x: 0, y: 0)
            .onAppear {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .frame(minWidth: 30, minHeight: 20)
            .padding(.horizontal, 3)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
    }
}

// MARK: - Reusable Glass Panel

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 14
    var tint: Double = 0.05

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(tint))
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.28),
                                Color.white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 3)
    }
}

extension View {
    func glassPanel(cornerRadius: CGFloat = 14) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius))
    }
}

struct GlassIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 18, height: 18)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

#Preview {
    MonitorView(apollo: ApolloController())
}
