import AppKit
import Foundation
import UserNotifications

/// Owns the UAD background process lifecycle for ApolloRemote.
///
/// ApolloRemote intentionally launches the UA Mixer Engine executable directly
/// instead of opening UA Console. Apollo Remote owns the Mixer Engine session
/// while it is open and shuts down the engine and its helper processes on quit.
final class UABackendManager {
    static let shared = UABackendManager()

    private let mixerEnginePath = "/Library/Application Support/Universal Audio/Apollo/UA Mixer Engine.app/Contents/MacOS/UA Mixer Engine"
    private let mixerEngineBundleID = "com.uaudio.engine"

    /// UA apps quit on disconnect (name patterns / bundle IDs).
    private let uaQuitPatterns = [
        "UA Mixer Helper",
        "UA Mixer Engine Helper",
        "UA Mixer Helper.app",
        "UA Mixer Engine",
        "UAD Console",
        "UAD Meter"
    ]
    private let uaQuitBundleIDs = [
        "com.uaudio.engine",
        "com.uaudio.console",
        "com.uaudio.UADMeter"
    ]

    private var mixerEngineProcess: Process?
    private var mixerEnginePID: Int32?
    private var ownsMixerEngine = false
    private var ownedDescendantPIDs = Set<Int32>()
    private var disconnectQuitWorkItem: DispatchWorkItem?
    private static let disconnectGraceSeconds: TimeInterval = 7.0

    private init() {}

    /// Starts UA Mixer Engine before ApolloRemote creates its TCP controller.
    /// `completion` fires on the main queue once the engine is confirmed running,
    /// couldn't be found, or the timeout elapsed. Runs on a background queue —
    /// this does real shell-out work (`pgrep`/`ps`) and should never be allowed
    /// to block the main thread during app launch.
    func startBeforeConnection(timeout: TimeInterval = 5.0, completion: @escaping (Bool) -> Void = { _ in }) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            if self.isMixerEngineRunning() {
                // Apollo Remote owns the mixer session for its lifetime,
                // including when the engine was already running at launch.
                self.ownsMixerEngine = true
                self.refreshExistingMixerEngineProcess()
                DispatchQueue.main.async { completion(true) }
                return
            }

            let started = self.launchMixerEngine(timeout: timeout)
            DispatchQueue.main.async {
                if started {
                    self.postNotificationIfEnabled(
                        key: "notifyOnMixerStart",
                        title: "UA Mixer Engine",
                        body: "Mixer Engine started for Apollo."
                    )
                }
                completion(started)
            }
        }
    }

    /// Manually boots UA Mixer Engine on demand — for the "Launch UA Mixer
    /// Engine" button, used when Apollo Remote (or the engine itself) was
    /// quit independently and needs a manual kick to come back up.
    /// Ignores the `autoStartMixerEngine` setting since this is an explicit
    /// user action, not the automatic flow.
    func manualLaunchMixerEngine(completion: @escaping (Bool) -> Void = { _ in }) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            if self.isMixerEngineRunning() {
                self.ownsMixerEngine = true
                self.refreshExistingMixerEngineProcess()
                DispatchQueue.main.async { completion(true) }
                return
            }

            let started = self.launchMixerEngine(timeout: 5.0)
            DispatchQueue.main.async {
                if started {
                    self.postNotificationIfEnabled(
                        key: "notifyOnMixerStart",
                        title: "UA Mixer Engine",
                        body: "Mixer Engine started manually."
                    )
                }
                completion(started)
            }
        }
    }

    /// Called when an Apollo device is detected online while the app is running.
    /// Mixer Engine startup is mandatory; there is no user-facing toggle.
    func ensureMixerRunningOnDeviceDetect() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.isMixerEngineRunning() {
                self.ownsMixerEngine = true
                self.refreshExistingMixerEngineProcess()
                return
            }
            let started = self.launchMixerEngine(timeout: 5.0)
            if started {
                DispatchQueue.main.async {
                    self.postNotificationIfEnabled(
                        key: "notifyOnMixerStart",
                        title: "UA Mixer Engine",
                        body: "Apollo detected — Mixer Engine started."
                    )
                }
            }
        }
    }

    /// Schedule quitting UA apps after a grace window with no Apollo online.
    /// Cancelled if a device comes back before the timer fires.
    /// `onQuit` fires on the main queue once the UA apps have actually been
    /// told to quit (helpers terminated, engine terminated) — never on a
    /// separate timer of its own — so callers can safely chain further
    /// shutdown behavior (like also quitting Apollo Remote) off of it.
    /// This lifecycle shutdown is mandatory and has no user-facing toggle.
    func scheduleAutoQuitOnDisconnect(onQuit: (() -> Void)? = nil) {
        disconnectQuitWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.quitUAAppsAndNotify(completion: onQuit)
        }
        disconnectQuitWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.disconnectGraceSeconds, execute: work)
    }

    func cancelAutoQuitOnDisconnect() {
        disconnectQuitWorkItem?.cancel()
        disconnectQuitWorkItem = nil
    }

    private func launchMixerEngine(timeout: TimeInterval) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: mixerEnginePath) else {
            NSLog("ApolloRemote: UA Mixer Engine not found at \(mixerEnginePath)")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: mixerEnginePath)
        process.arguments = []
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            mixerEngineProcess = process
            ownsMixerEngine = true
        } catch {
            NSLog("ApolloRemote: failed to start UA Mixer Engine: \(error)")
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if process.isRunning || isMixerEngineRunning() {
                Thread.sleep(forTimeInterval: 0.25)
                refreshOwnedDescendants()
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        NSLog("ApolloRemote: UA Mixer Engine did not report running before timeout")
        return process.isRunning
    }

    /// `completion` fires on the main queue after the UA apps have been told
    /// to quit — success meaning "the shutdown was attempted and completed",
    /// not that every process is guaranteed gone (SIGKILL above already
    /// backstops that). Callers that need to chain further shutdown steps
    /// off a *successful* UA quit should use this rather than their own timer.
    private func quitUAAppsAndNotify(completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?() }
                return
            }
            self.terminateMixerHelpers()
            self.terminateRunningMixerEngineByPath()
            for pattern in self.uaQuitPatterns {
                self.terminateMatching(pattern: pattern)
            }
            for app in NSWorkspace.shared.runningApplications {
                if let bid = app.bundleIdentifier, self.uaQuitBundleIDs.contains(bid) {
                    app.terminate()
                }
            }
            self.ownsMixerEngine = false
            self.mixerEngineProcess = nil
            self.mixerEnginePID = nil
            self.ownedDescendantPIDs.removeAll()

            DispatchQueue.main.async {
                self.postNotificationIfEnabled(
                    key: "notifyOnUAQuit",
                    title: "UA Apps Quit",
                    body: "Apollo disconnected — UA Mixer Engine and helpers were quit."
                )
                completion?()
            }
        }
    }

    private func terminateMatching(pattern: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", pattern]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return }
            for token in text.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }) {
                if let pid = Int32(token), pid > 0 { terminate(pid: pid) }
            }
        } catch {}
    }

    func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postNotificationIfEnabled(key: String, title: String, body: String) {
        guard UserDefaults.standard.bool(forKey: key) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "apollo.\(key).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    /// Stops the UAD engine session and its helper processes.
    /// Runs entirely on a background queue — this walks the process tree and
    /// sends signals with grace-period sleeps per process, which is real wall
    /// clock time that must never freeze the main thread during quit.
    /// `completion` always fires on the main queue.
    func stop(completion: @escaping () -> Void = {}) {
        guard ownsMixerEngine else {
            DispatchQueue.main.async(execute: completion)
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                DispatchQueue.main.async(execute: completion)
                return
            }

            // Capture children/helpers before terminating the parent, because macOS
            // may re-parent them immediately after the parent exits.
            self.refreshOwnedDescendants()

            for pid in self.ownedDescendantPIDs.sorted(by: >) {
                self.terminate(pid: pid)
            }

            if let process = self.mixerEngineProcess, process.isRunning {
                self.terminate(pid: process.processIdentifier)
                process.waitUntilExit()
            } else {
                self.terminateRunningMixerEngineByPath()
            }

            self.terminateMixerHelpers()
            self.ownedDescendantPIDs.removeAll()
            self.mixerEngineProcess = nil
            self.mixerEnginePID = nil
            self.ownsMixerEngine = false

            DispatchQueue.main.async(execute: completion)
        }
    }

    private func refreshExistingMixerEngineProcess() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", NSRegularExpression.escapedPattern(for: mixerEnginePath)]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8),
                  let pid = text.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
                    .compactMap({ Int32($0) })
                    .first(where: { $0 > 0 }) else { return }
            mixerEnginePID = pid
            refreshOwnedDescendants(rootPID: pid)
        } catch {
            NSLog("ApolloRemote: could not recover existing UA Mixer Engine process: \(error)")
        }
    }

    private func isMixerEngineRunning() -> Bool {
        if let process = mixerEngineProcess, process.isRunning {
            return true
        }

        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == mixerEngineBundleID
        }) {
            return true
        }

        return processExists(matchingExecutablePath: mixerEnginePath)
    }

    /// Finds child processes recursively. UA Mixer Engine normally owns/starts
    /// its helper process, so this catches the helper without hard-coding a
    /// potentially version-specific helper path.
    private func refreshOwnedDescendants() {
        guard let rootPID = mixerEngineProcess?.processIdentifier ?? mixerEnginePID,
              rootPID > 0 else { return }
        refreshOwnedDescendants(rootPID: rootPID)
    }

    private func refreshOwnedDescendants(rootPID: Int32) {
        var all = Set<Int32>()
        var frontier: Set<Int32> = [rootPID]

        while !frontier.isEmpty {
            var next = Set<Int32>()

            for parent in frontier {
                for child in directChildren(of: parent) {
                    if child != rootPID && all.insert(child).inserted {
                        next.insert(child)
                    }
                }
            }

            frontier = next
        }

        ownedDescendantPIDs.formUnion(all)
    }

    private func terminateRunningMixerEngineByPath() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", NSRegularExpression.escapedPattern(for: mixerEnginePath)]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return }
            for token in text.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }) {
                if let pid = Int32(token), pid > 0 { terminate(pid: pid) }
            }
        } catch {
            NSLog("ApolloRemote: could not locate UA Mixer Engine for shutdown: \(error)")
        }
    }

    private func terminateMixerHelpers() {
        // UA has changed helper naming across releases, so match the known
        // Mixer Helper command/path variants rather than relying on one PID.
        let patterns = [
            "UA Mixer Helper",
            "UA Mixer Engine Helper",
            "UA Mixer Helper.app"
        ]

        for pattern in patterns {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            task.arguments = ["-f", pattern]
            let output = Pipe()
            task.standardOutput = output
            task.standardError = FileHandle.nullDevice

            do {
                try task.run()
                task.waitUntilExit()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8) else { continue }
                for token in text.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }) {
                    if let pid = Int32(token), pid > 0 { terminate(pid: pid) }
                }
            } catch {
                NSLog("ApolloRemote: could not locate UA Mixer helper processes: \(error)")
            }
        }
    }

    private func directChildren(of parentPID: Int32) -> Set<Int32> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,ppid="]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }

            var children = Set<Int32>()
            for line in text.split(separator: "\n") {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                guard fields.count >= 2,
                      let pid = Int32(fields[0]),
                      let ppid = Int32(fields[1]),
                      ppid == parentPID else { continue }
                children.insert(pid)
            }
            return children
        } catch {
            return []
        }
    }

    private func processExists(matchingExecutablePath path: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", NSRegularExpression.escapedPattern(for: path)]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func terminate(pid: Int32) {
        guard pid > 0 else { return }
        kill(pid, SIGTERM)

        // Give a well-behaved UAD helper a short grace period.
        Thread.sleep(forTimeInterval: 0.15)

        if kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
    }
}
