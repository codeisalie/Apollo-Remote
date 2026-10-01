import Foundation
import Combine
import WidgetKit

/// Connection state for the UI
public enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case retrying(attempt: Int)
    case connected
    case enumerating
}

/// Main controller for Apollo monitor controls
/// Manages connection, device enumeration, and monitor state
public class ApolloController: ObservableObject {

    // MARK: - Monitor State

    @Published public var volume: Double = 0 {
        didSet {
            guard !isReceiving else { return }
            scheduleVolumeSend()
        }
    }

    /// The Apollo's own tapered monitor-knob position, as reported by
    /// `CRMonitorLevelTapered` (0...1). This is the source of truth for the
    /// menu-bar arc and slider position; it is not reconstructed from dB.
    @Published public var volumeTapered: Double = 0 {
        didSet {
            guard !isReceiving else { return }
            scheduleTaperedSend()
        }
    }

    // Tracks the value actually sent to hardware, separate from `volume` itself.
    // Diffing against this (rather than the didSet's `oldValue`) is what lets the
    // threshold check accumulate drift across many small updates during a slow
    // drag, instead of resetting its baseline every single update.
    private var lastSentVolume: Double = 0
    private var volumeFlushWorkItem: DispatchWorkItem?
    private var lastSentTapered: Double = 0
    private var taperedFlushWorkItem: DispatchWorkItem?

    /// True only after the selected Apollo has reported its real monitor state.
    /// Until then the UI must not present a local/default volume as authoritative.
    @Published public private(set) var monitorStateReady = false

    @Published public var isMuted = false {
        didSet { if !isReceiving { syncToWidget() } }
    }
    @Published public var isDimmed = false {
        didSet { if !isReceiving { syncToWidget() } }
    }
    @Published public var isMono = false {
        didSet { if !isReceiving { syncToWidget() } }
    }

    // MARK: - Connection State

    @Published public var isConnected = false {
        didSet { syncToWidget() }
    }
    @Published public var connectionState: ConnectionState = .disconnected
    @Published public var statusMessage = "Disconnected"

    // MARK: - Device Enumeration

    @Published public var devices: [UADevice] = []
    @Published public var outputs: [UAOutput] = []
    @Published public var selectedHost: UAHost = .localhost
    @Published public var selectedDeviceId: String = "0"
    @Published public var selectedOutputId: String = "4"
    @Published public var deviceName: String = "Apollo"

    // MARK: - Host Management

    @Published public var knownHosts: [UAHost] = [.localhost]

    // MARK: - Computed

    public var volumeDisplay: String {
        let dB = volumeToDB(volume)
        return dB <= -95 ? "-\u{221E}" : String(format: "%.1f", dB)
    }

    var basePath: String {
        "/devices/\(selectedDeviceId)/outputs/\(selectedOutputId)"
    }

    /// True only when the currently selected Apollo is actually reporting online —
    /// not just when we have a live TCP session to UA Mixer Engine. Mixer Engine
    /// can be running with no interface connected/powered, and this is what
    /// distinguishes that case.
    public var isDeviceOnline: Bool {
        devices.first(where: { $0.id == selectedDeviceId })?.isOnline ?? false
    }

    // MARK: - Private

    private var tcp: ApolloTCP?
    private var isReceiving = false
    private var isEnumerated = false
    private var pendingDeviceCount = 0
    private var pendingOutputEnumeration = false
    private var enumerationWatchdog: DispatchWorkItem?
    private var widgetHeartbeatTimer: Timer?
    private var suppressExternalOverlayUntil: CFAbsoluteTime = 0
    private var hasUserSelectedOutput = false


    // MARK: - Init

    public init() {
        loadPersistedState()
        connectToHost(selectedHost)
        startWidgetHeartbeat()
    }

    /// Refreshes `widgetLastUpdate` periodically even when nothing else changes, so
    /// the widget can tell "app running, state just hasn't changed" apart from
    /// "app not running / crashed" instead of showing indefinitely stale data.
    private func startWidgetHeartbeat() {
        widgetHeartbeatTimer?.invalidate()
        widgetHeartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.syncToWidget()
        }
    }

    // MARK: - Connection

    /// Connect to a specific host
    public func connectToHost(_ host: UAHost) {
        // A trailing slider flush belongs to the old connection. Never let it
        // write the old Apollo's value after the host changes.
        volumeFlushWorkItem?.cancel()
        volumeFlushWorkItem = nil
        taperedFlushWorkItem?.cancel()
        taperedFlushWorkItem = nil
        tcp?.disconnect()
        devices = []
        outputs = []
        hasUserSelectedOutput = false
        resetMonitorStateForNewConnection()

        selectedHost = host
        connectionState = .connecting
        statusMessage = "Connecting to \(host.displayName)…"

        if host.isLocalhost {
            startTCPConnection(host: host.address, port: host.port)
        } else {
            startTCPConnection(host: host.address, port: host.port)
        }

        savePersistedState()
    }

    /// Manual reconnect from UI
    public func reconnect() {
        tcp?.resetReconnectCounter()
        connectToHost(selectedHost)
    }

    /// Change the selected device (re-subscribes to its outputs)
    public func selectDevice(_ deviceId: String) {
        guard deviceId != selectedDeviceId else { return }
        hasUserSelectedOutput = false
        selectedDeviceId = deviceId
        resetMonitorStateForNewConnection()

        if let device = devices.first(where: { $0.id == deviceId }) {
            deviceName = device.name
        }

        outputs = []
        tcp?.get("/devices/\(deviceId)/outputs")
        pendingOutputEnumeration = true

        savePersistedState()
    }

    /// Change the selected output (re-subscribes to its values).
    /// Output is always forced to Monitor — the UI no longer exposes an output picker.
    public func selectOutput(_ outputId: String) {
        volumeFlushWorkItem?.cancel()
        volumeFlushWorkItem = nil
        taperedFlushWorkItem?.cancel()
        taperedFlushWorkItem = nil

        // Prefer MONITOR by name when available; otherwise accept the requested id.
        if let monitor = outputs.first(where: {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("MONITOR") == .orderedSame
        }) {
            guard monitor.id != selectedOutputId else { return }
            selectedOutputId = monitor.id
        } else {
            guard outputId != selectedOutputId else { return }
            selectedOutputId = outputId
        }
        hasUserSelectedOutput = false
        resetMonitorStateForNewConnection()
        subscribeToMonitorValues()
        savePersistedState()
    }

    // MARK: - Host Management

    public func addHost(_ host: UAHost) {
        guard !knownHosts.contains(where: { $0.id == host.id }) else { return }
        knownHosts.append(host)
        saveHosts()
    }

    public func removeHost(_ host: UAHost) {
        guard host.id != UAHost.localhost.id else { return }
        knownHosts.removeAll { $0.id == host.id }
        saveHosts()
    }

    public func mergeDiscoveredHosts(_ discovered: [UAHost]) {
        for host in discovered {
            if !knownHosts.contains(where: { $0.address == host.address }) {
                knownHosts.append(host)
            }
        }
        saveHosts()
    }

    // MARK: - TCP Setup

    private func startTCPConnection(host: String, port: UInt16) {
        tcp = ApolloTCP(host: host, port: port)

        tcp?.onStatus = { [weak self] connected, message in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isConnected = connected
                self.statusMessage = message

                if connected {
                    self.connectionState = .enumerating
                    self.startDeviceEnumeration()
                } else if message.contains("Connecting") {
                    self.connectionState = .connecting
                } else if case .retrying = self.connectionState {
                    // onReconnectAttempt already set the precise attempt count for this
                    // state; don't downgrade it back to .disconnected on the matching
                    // status-text update for the same event.
                } else {
                    self.connectionState = .disconnected
                }
            }
        }

        // Structured signal for retry state — avoids parsing onStatus's display text.
        tcp?.onReconnectAttempt = { [weak self] attempt in
            DispatchQueue.main.async {
                self?.connectionState = .retrying(attempt: attempt)
            }
        }

        tcp?.onResponse = { [weak self] response in
            DispatchQueue.main.async {
                self?.handleResponse(response)
            }
        }

        tcp?.onDisconnected = { [weak self] in
            DispatchQueue.main.async {
                self?.connectionState = .retrying(attempt: 1)
                self?.isEnumerated = false
                self?.devices = []
                self?.outputs = []
            }
        }

        tcp?.connect()
    }

    // MARK: - Device Enumeration

    private func startDeviceEnumeration() {
        statusMessage = "Enumerating devices…"
        devices = []
        outputs = []
        pendingDeviceCount = 0
        isEnumerated = false
        tcp?.get("/devices")
        scheduleEnumerationWatchdog()
    }

    /// Device/output enumeration is driven entirely by counting expected responses
    /// (pendingDeviceCount, pendingOutputEnumeration). If any single device or the
    /// output list never answers — a protocol quirk, a race, a device in a weird
    /// state — that counting-based state machine has no way to notice and just
    /// waits forever on "Enumerating devices…". This watchdog forces completion
    /// with whatever was actually resolved so the UI never gets stuck.
    private func scheduleEnumerationWatchdog() {
        enumerationWatchdog?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.connectionState == .enumerating else { return }
            NSLog("ApolloRemote: enumeration timed out — proceeding with partial data")
            self.pendingDeviceCount = 0
            self.pendingOutputEnumeration = false
            if self.outputs.isEmpty {
                self.finishDeviceEnumeration()
            } else {
                self.isEnumerated = true
                self.connectionState = .connected
                self.statusMessage = "Connected — \(self.deviceName) (partial)"
            }
        }
        enumerationWatchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    // MARK: - Response Handling

    private func handleResponse(_ response: UAResponse) {
        switch response {
        case .children(let path, let ids):
            if path == "/devices" {
                handleDeviceList(ids)
            } else if path.hasSuffix("/outputs") {
                handleOutputList(path: path, ids: ids)
            }

        case .stringValue(let path, let property, let value):
            if property == "DeviceName" {
                handleDeviceNameUpdate(path: path, value: value)
            } else if property == "Name" {
                handleOutputNameUpdate(path: path, value: value)
            }

        case .boolValue(let path, let property, let value):
            if property == "DeviceOnline" {
                handleDeviceOnlineUpdate(path: path, online: value)
            } else {
                handleMonitorBoolUpdate(path: path, property: property, value: value)
            }

        case .value(let path, let property, let doubleValue):
            if property == "DeviceOnline" {
                // Some Mixer Engine versions serialize this property as 0/1
                // instead of a JSON boolean.
                handleDeviceOnlineUpdate(path: path, online: doubleValue != 0)
            } else {
                handleMonitorValueUpdate(path: path, property: property, value: doubleValue)
            }
        }
    }

    private func handleDeviceList(_ ids: [String]) {
        // Skip if already enumerated (keep-alive pings trigger this too)
        guard !isEnumerated else { return }

        pendingDeviceCount = ids.count
        for id in ids {
            let device = UADevice(id: id)
            if !devices.contains(where: { $0.id == id }) {
                devices.append(device)
            }
            tcp?.get("/devices/\(id)")
            tcp?.subscribe("/devices/\(id)/DeviceOnline/value")
        }

        if ids.isEmpty {
            statusMessage = "No devices found"
            connectionState = .connected
        }
    }

    /// Match device name by path (e.g. "/devices/0" or "/devices/0/DeviceName")
    private func handleDeviceNameUpdate(path: String, value: String) {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "devices" else { return }
        let deviceId = String(parts[1])

        if let idx = devices.firstIndex(where: { $0.id == deviceId }) {
            devices[idx].name = value
            pendingDeviceCount -= 1

            if pendingDeviceCount <= 0 {
                finishDeviceEnumeration()
            }
        }
    }

    /// Match output name by path (e.g. "/devices/0/outputs/4" or "/devices/0/outputs/4/Name")
    private func handleOutputNameUpdate(path: String, value: String) {
        let parts = path.split(separator: "/")
        guard let outputsIdx = parts.firstIndex(of: "outputs"),
              outputsIdx + 1 < parts.count else { return }
        let outputId = String(parts[outputsIdx + 1])

        if let idx = outputs.firstIndex(where: { $0.id == outputId }) {
            outputs[idx].name = value.isEmpty ? "Output \(outputId)" : value

            // Output 4 is common on a Twin, but it is not a protocol
            // guarantee. Prefer the actual MONITOR node during discovery
            // unless the user explicitly picked another output.
            if !hasUserSelectedOutput,
               value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare("MONITOR") == .orderedSame,
               selectedOutputId != outputId {
                selectedOutputId = outputId
                subscribeToMonitorValues()
                savePersistedState()
            }
        }
    }

    private func handleDeviceOnlineUpdate(path: String, online: Bool) {
        let parts = path.split(separator: "/")
        guard parts.count >= 2, parts[0] == "devices" else { return }
        let deviceId = String(parts[1])

        if let idx = devices.firstIndex(where: { $0.id == deviceId }) {
            devices[idx].isOnline = online
        }
    }

    private func finishDeviceEnumeration() {
        // Re-arm the watchdog for the output-enumeration phase we're about to start —
        // it can hang the same way device enumeration can (see scheduleEnumerationWatchdog).
        scheduleEnumerationWatchdog()

        // Auto-select: prefer last used, then first online, then first
        let lastId = selectedDeviceId
        if let _ = devices.first(where: { $0.id == lastId && $0.isOnline }) {
            // Keep current selection
        } else if let firstOnline = devices.first(where: { $0.isOnline }) {
            selectedDeviceId = firstOnline.id
        } else if let first = devices.first {
            selectedDeviceId = first.id
        }

        if let device = devices.first(where: { $0.id == selectedDeviceId }) {
            deviceName = device.name
        }

        tcp?.get("/devices/\(selectedDeviceId)/outputs")
        pendingOutputEnumeration = true
    }

    private func handleOutputList(path: String, ids: [String]) {
        guard pendingOutputEnumeration else { return }
        pendingOutputEnumeration = false

        // Create outputs with default names — protocol will update via Name property
        outputs = ids.map { UAOutput(id: $0, name: "Output \($0)") }

        // Query name for each output
        for id in ids {
            tcp?.get("/devices/\(selectedDeviceId)/outputs/\(id)")
        }

        // Always lock to Monitor: prefer id "4" (common MONITOR path), else first.
        // Name-based MONITOR preference is applied when Name properties arrive.
        if outputs.contains(where: { $0.id == "4" }) {
            selectedOutputId = "4"
        } else if let first = outputs.first {
            selectedOutputId = first.id
        }
        hasUserSelectedOutput = false

        isEnumerated = true
        connectionState = .connected
        statusMessage = "Connected — \(deviceName)"
        subscribeToMonitorValues()
        savePersistedState()
    }

    // MARK: - Subscribe & Monitor Values

    /// Clear the local presentation whenever the Apollo target changes. The next
    /// hardware report becomes the only value allowed to populate the slider.
    private func resetMonitorStateForNewConnection() {
        monitorStateReady = false
        isReceiving = true
        volume = 0
        volumeTapered = 0
        isMuted = false
        isDimmed = false
        isMono = false
        isReceiving = false
        lastSentVolume = 0
        lastSentTapered = 0
    }

    private func subscribeToMonitorValues() {
        let props = ["CRMonitorLevelTapered", "CRMonitorLevel", "Mute", "DimOn", "MixToMono"]
        for prop in props {
            let path = "\(basePath)/\(prop)/value"
            tcp?.subscribe(path)
            tcp?.get(path)
        }
    }

    private func handleMonitorValueUpdate(path: String, property: String, value: Double) {
        guard isSelectedMonitorProperty(path: path, property: property) else { return }

        isReceiving = true
        defer { isReceiving = false }

        switch property {
        case "CRMonitorLevelTapered":
            taperedFlushWorkItem?.cancel()
            taperedFlushWorkItem = nil
            volumeTapered = min(1, max(0, value))
            lastSentTapered = volumeTapered
            monitorStateReady = true
        case "CRMonitorLevel":
            volumeFlushWorkItem?.cancel()
            volumeFlushWorkItem = nil
            volume = dbToVolume(value)
            lastSentVolume = volume
            monitorStateReady = true
        case "Mute":
            isMuted = value != 0
        case "DimOn":
            isDimmed = value != 0
        case "MixToMono":
            isMono = value != 0
        default:
            break
        }

        if property != "CRMonitorLevelTapered",
           UserDefaults.standard.bool(forKey: "volumeOverlayEnabled"),
           CFAbsoluteTimeGetCurrent() > suppressExternalOverlayUntil {
            VolumeOverlayController.shared.show(for: self)
        }
        syncToWidget()
    }

    private func handleMonitorBoolUpdate(path: String, property: String, value: Bool) {
        guard isSelectedMonitorProperty(path: path, property: property) else { return }

        isReceiving = true
        defer { isReceiving = false }

        switch property {
        case "Mute":
            isMuted = value
        case "DimOn":
            isDimmed = value
        case "MixToMono":
            isMono = value
        default:
            break
        }

        if UserDefaults.standard.bool(forKey: "volumeOverlayEnabled"), CFAbsoluteTimeGetCurrent() > suppressExternalOverlayUntil {
            VolumeOverlayController.shared.show(for: self)
        }
        syncToWidget()
    }

    /// `get /devices/{id}/outputs/{id}` returns every property for that output.
    /// During enumeration we also query every output for its display name, so
    /// accepting a monitor property without checking its path makes another
    /// output overwrite the selected volume/mute state.
    private func isSelectedMonitorProperty(path: String, property: String) -> Bool {
        let selectedPath = basePath
        return path == selectedPath
            || path == "\(selectedPath)/\(property)"
            || path == "\(selectedPath)/\(property)/value"
    }

    // MARK: - Volume Send Coalescing

    /// Sends volume to hardware immediately once drift from the last-sent value
    /// crosses the threshold (keeps a live drag feeling responsive), and otherwise
    /// schedules a short trailing flush of the exact current value. That trailing
    /// flush is what guarantees a slow, fine-grained drag still ends up in sync
    /// with the hardware once it settles — without it, a run of sub-threshold
    /// updates could leave the two arbitrarily out of sync.
    private func scheduleVolumeSend() {
        // Hardware-authority gate: never write a local/default value to Apollo
        // before the selected device has reported its real monitor state.
        guard monitorStateReady else { return }
        volumeFlushWorkItem?.cancel()

        if abs(lastSentVolume - volume) > 0.3 {
            sendVolumeNow()
        } else {
            let workItem = DispatchWorkItem { [weak self] in self?.sendVolumeNow() }
            volumeFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
        }
    }

    private func scheduleTaperedSend() {
        // Hardware-authority gate: never write a local/default value to Apollo
        // before the selected device has reported its real monitor state.
        guard monitorStateReady else { return }
        taperedFlushWorkItem?.cancel()

        if abs(lastSentTapered - volumeTapered) > 0.005 {
            sendTaperedNow()
        } else {
            let workItem = DispatchWorkItem { [weak self] in self?.sendTaperedNow() }
            taperedFlushWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
        }
    }

    private func sendVolumeNow() {
        volumeFlushWorkItem?.cancel()
        guard monitorStateReady else { return }
        volumeFlushWorkItem = nil
        guard tcp?.isConnected == true else { return }
        suppressExternalOverlayUntil = CFAbsoluteTimeGetCurrent() + 0.25
        lastSentVolume = volume
        tcp?.set("\(basePath)/CRMonitorLevel", value: volumeToDB(volume))
        syncToWidget()
    }

    private func sendTaperedNow() {
        taperedFlushWorkItem?.cancel()
        guard monitorStateReady else { return }
        taperedFlushWorkItem = nil
        guard tcp?.isConnected == true else { return }
        suppressExternalOverlayUntil = CFAbsoluteTimeGetCurrent() + 0.25
        lastSentTapered = volumeTapered
        tcp?.set("\(basePath)/CRMonitorLevelTapered", value: volumeTapered)
        syncToWidget()
    }

    // MARK: - Public Actions

    /// Change monitor level by a dB amount (fine path via CRMonitorLevel).
    public func increaseVolume(byDB step: Double = 3) {
        guard monitorStateReady else { return }
        let newDB = min(0, volumeToDB(volume) + max(0, step))
        volume = dbToVolume(newDB)
    }

    public func decreaseVolume(byDB step: Double = 3) {
        guard monitorStateReady else { return }
        let newDB = max(-96, volumeToDB(volume) - max(0, step))
        volume = dbToVolume(newDB)
    }

    /// Step the hardware tapered knob (CRMonitorLevelTapered) by N detents.
    /// The Apollo snaps tapered to a 1/54 grid — this is the smooth path that
    /// matches the on-screen slider and avoids the dB/tapered fight that made
    /// volume keys feel choppy.
    public func stepTapered(detents: Int) {
        guard monitorStateReady, detents != 0 else { return }
        let grid = 54.0
        let current = volumeTapered
        // Snap to nearest detent, then move.
        let index = (current * grid).rounded()
        let next = min(grid, max(0, index + Double(detents)))
        volumeTapered = next / grid
    }

    /// Set the hardware's tapered monitor-knob position from the menu slider.
    public func setTaperedPercent(_ percent: Double) {
        guard monitorStateReady else { return }
        volumeTapered = min(1, max(0, percent / 100.0))
    }

    public func toggleMute() {
        suppressExternalOverlayUntil = CFAbsoluteTimeGetCurrent() + 0.25
        isMuted.toggle()
        tcp?.set("\(basePath)/Mute", value: isMuted)
    }

    public func toggleDim() {
        suppressExternalOverlayUntil = CFAbsoluteTimeGetCurrent() + 0.25
        isDimmed.toggle()
        tcp?.set("\(basePath)/DimOn", value: isDimmed)
    }

    public func toggleMono() {
        isMono.toggle()
        tcp?.set("\(basePath)/MixToMono", value: isMono)
    }

    // MARK: - Persistence

    private func loadPersistedState() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: "savedHosts"),
           let hosts = try? JSONDecoder().decode([UAHost].self, from: data) {
            knownHosts = hosts
            if !knownHosts.contains(where: { $0.isLocalhost }) {
                knownHosts.insert(.localhost, at: 0)
            }
        }

        if let address = defaults.string(forKey: "lastHostAddress") {
            let port = UInt16(defaults.integer(forKey: "lastHostPort"))
            let portValue = port > 0 ? port : 4710
            let name = defaults.string(forKey: "lastHostName") ?? address

            selectedHost = knownHosts.first(where: { $0.address == address && $0.port == portValue })
                ?? UAHost(address: address, port: portValue, displayName: name, isManual: true)
        }

        selectedDeviceId = defaults.string(forKey: "lastDeviceId") ?? "0"
        selectedOutputId = defaults.string(forKey: "lastOutputId") ?? "4"
    }

    // Volume is intentionally NOT persisted. The Apollo hardware is always the
    // source of truth and its reported value is re-read on every connection.
    private func savePersistedState() {
        let defaults = UserDefaults.standard
        defaults.set(selectedHost.address, forKey: "lastHostAddress")
        defaults.set(Int(selectedHost.port), forKey: "lastHostPort")
        defaults.set(selectedHost.displayName, forKey: "lastHostName")
        defaults.set(selectedDeviceId, forKey: "lastDeviceId")
        defaults.set(selectedOutputId, forKey: "lastOutputId")
    }

    private func saveHosts() {
        if let data = try? JSONEncoder().encode(knownHosts) {
            UserDefaults.standard.set(data, forKey: "savedHosts")
        }
    }

    // MARK: - Widget Sync (App Group)

    private func syncToWidget() {
        sharedDefaults.set(volumeToDB(volume), forKey: "widgetVolume")
        sharedDefaults.set(isMuted, forKey: "widgetMuted")
        sharedDefaults.set(isDimmed, forKey: "widgetDimmed")
        sharedDefaults.set(isMono, forKey: "widgetMono")
        sharedDefaults.set(isConnected, forKey: "widgetConnected")
        sharedDefaults.set(deviceName, forKey: "widgetDeviceName")
        sharedDefaults.set(Date().timeIntervalSince1970, forKey: "widgetLastUpdate")

        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: - Volume Conversion (full -96 to 0 dB range, quadratic curve)

    private func volumeToDB(_ sliderValue: Double) -> Double {
        if sliderValue <= 0 { return -96.0 }
        if sliderValue >= 100 { return 0.0 }
        let normalized = sliderValue / 100.0
        let curved = pow(normalized, 2.0)
        return curved * 96.0 - 96.0
    }

    private func dbToVolume(_ dB: Double) -> Double {
        if dB <= -96 { return 0 }
        if dB >= 0 { return 100 }
        let normalized = (dB + 96.0) / 96.0
        return sqrt(normalized) * 100.0
    }
}
