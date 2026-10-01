<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="Apollo Remote" width="128">
</p>

<h1 align="center">Apollo Remote</h1>

<p align="center">
  <strong>Control your Universal Audio Apollo from anywhere on your network.</strong>
</p>

<p align="center">
  <a href="https://github.com/codeisalie/Apollo-Remote/releases">
    <img src="https://img.shields.io/github/v/release/codeisalie/Apollo-Remote?style=flat-square" alt="Release">
  </a>
  <img src="https://img.shields.io/badge/macOS-14.0+-blue?style=flat-square" alt="macOS 14.0+">
  <img src="https://img.shields.io/badge/Swift-5.10-orange?style=flat-square" alt="Swift 5.10">
  <a href="LICENSE">
    <img src="https://img.shields.io/github/license/codeisalie/Apollo-Remote?style=flat-square" alt="License">
  </a>
</p>

---

<img width="2688" height="1536" alt="Apollo Remote main interface" src="https://github.com/user-attachments/assets/76e79b09-3272-4c12-bfcd-5f08384d8c11" />

<img width="2688" height="1536" alt="Apollo Remote settings" src="https://github.com/user-attachments/assets/5e01dc4e-4a7b-4457-9d45-0ab15fa560ff" />

<img width="369" height="177" alt="Apollo Remote menu bar interface" src="https://github.com/user-attachments/assets/4c45dba6-37bd-41a3-94a2-1162ccf89394" />

## Overview

**Apollo Remote** is a native macOS menu bar application for controlling Universal Audio Apollo monitor output.

It can control an Apollo locally or remotely over your network, providing direct access to:

* Volume
* Mute
* Dim
* Mono

No need to keep UA Console visible on your screen. Apollo Remote lives in the macOS menu bar and provides quick access to your Apollo monitor controls.

## Features

| Feature                      | Description                                                                    |
| ---------------------------- | ------------------------------------------------------------------------------ |
| **Volume Control**           | Full-range volume control from -96 dB to 0 dB with real-time display           |
| **Mac Volume Keys**          | Directly maps the keyboard's volume and mute keys to the Apollo                |
| **Mute / Dim / Mono**        | One-click monitor controls with visual feedback                                |
| **Network Control**          | Connect to an Apollo through any Mac running UA Mixer Engine on your LAN       |
| **Auto-Discovery**           | Automatically discovers UA Mixer Engine instances using Bonjour                |
| **Multi-Device**             | Dynamically discovers and selects available Apollo devices and outputs         |
| **Real-Time Sync**           | Subscription-based updates provide immediate synchronization with the hardware |
| **Auto-Reconnect**           | Automatically reconnects using exponential backoff                             |
| **Mixer Engine Management**  | Starts and manages the required UA Mixer Engine process                        |
| **macOS Widget**             | WidgetKit widget displays volume, mute, dim, and mono status                   |
| **Persistent Configuration** | Remembers the last host, device, and output                                    |
| **Native UI**                | Built with SwiftUI and designed around Apple's macOS interface conventions     |
| **Zero Dependencies**        | Built entirely with Apple frameworks                                           |

## Requirements

* macOS 14.0 (Sonoma) or later
* Universal Audio Apollo interface:

  * Solo
  * Twin
  * x4
  * x6
  * x8
  * x8p
  * x16
* Universal Audio software with **UA Mixer Engine** available on the target Mac

## Installation

### Download

1. Download the latest `.dmg` from [Releases](https://github.com/codeisalie/Apollo-Remote/releases).
2. Open the DMG.
3. Drag **Apollo Remote** into your Applications folder.
4. On first launch, right-click the app and choose **Open**.

> **Note:** Apollo Remote is currently not notarized. macOS may block the first launch. Right-click the application, choose **Open**, and confirm **Open**. This is normally only required once.

### Build from Source

```bash
git clone https://github.com/codeisalie/Apollo-Remote.git
cd Apollo-Remote
xcodegen generate
open ApolloRemote.xcodeproj
```

**Requirements for building:**

* Xcode
* XcodeGen (`brew install xcodegen`)

Set your Development Team under **Signing & Capabilities**, then build and run the project.

## Usage

### Basic Controls

1. Click the Apollo Remote icon in the macOS menu bar.
2. Drag the volume slider to adjust the monitor level.
3. Click **Mute**, **Dim**, or **Mono** to toggle the corresponding control.
4. Click outside the popover to dismiss it.

### Remote Control

Apollo Remote can connect to UA Mixer Engine instances running on other Macs on the same network.

1. Click the **gear icon** in the popover footer.
2. Open **Settings → Connection**.
3. Available hosts discovered on the network will appear automatically.
4. Select the desired host.
5. Select the Apollo device and output.
6. Apollo Remote will connect and begin synchronizing with the selected output.

If automatic discovery does not find the desired host, a host can also be entered manually.

## Mac Volume Keys

Apollo Remote can take over the Mac's volume-up, volume-down, and mute keys and send those commands directly to the Apollo monitor output.

This requires **Accessibility** permission because macOS only allows applications to monitor system-wide keyboard events after the user has explicitly granted permission.

### Enabling Volume Keys

1. Launch Apollo Remote.
2. When macOS requests Accessibility permission, click **Open System Settings**.
3. Enable **Apollo Remote** under:
   **System Settings → Privacy & Security → Accessibility**
4. Apollo Remote detects the permission automatically without requiring a restart.

You can also check the permission status from:

**Apollo Remote → Settings → Keyboard → Authorize…**

### How the Keys Work

When Apollo Remote is enabled and the Apollo is the Mac's current output device:

* Volume Up → Apollo monitor volume up
* Volume Down → Apollo monitor volume down
* Mute → Apollo monitor mute

The keys are intercepted directly. No **Fn**, **⌘**, or additional modifier is required.

The behavior works regardless of whether **"Use F1, F2, etc. keys as standard function keys"** is enabled in macOS Keyboard settings.

> **Important:** The Apollo must be selected as the Mac's current output device for the volume keys to take over.

## Settings

Settings are accessible through the **gear icon** in the main popover.

| Tab            | Options                                                                |
| -------------- | ---------------------------------------------------------------------- |
| **Connection** | Host discovery, manual host entry, device selection, output selection  |
| **Keyboard**   | Accessibility status, volume-key control, step size, mute-key behavior |
| **Audio**      | Keyboard volume step size                                              |
| **General**    | Launch at login, application information                               |

## Widget

Apollo Remote includes a macOS WidgetKit extension.

The widget is available in small and medium sizes and displays:

* Current monitor volume
* Mute status
* Dim status
* Mono status

The widget receives its state from the main application through the shared App Group.

## How It Works

Apollo Remote communicates with **UA Mixer Engine** using the same internal network protocol used by Universal Audio's software.

```text
Transport: TCP/IP
Port:      4710
Host:      Any Mac running UA Mixer Engine
Format:    JSON over null-terminated strings
Sync:      Subscribe-based push updates
```

### Connection Flow

```text
1. Connect to host:4710
2. GET /devices
3. GET /devices/{id}
4. GET /devices/{id}/outputs
5. Subscribe to monitor-level and monitor-state properties
6. Receive real-time updates from UA Mixer Engine
```

### Protocol Commands

| Command     | Example                                                |
| ----------- | ------------------------------------------------------ |
| `get`       | `get /devices/0/outputs/4/CRMonitorLevel`              |
| `set`       | `set /devices/0/outputs/4/CRMonitorLevel/value/ -24.0` |
| `subscribe` | `subscribe /devices/0/outputs/4/Mute`                  |

## UAD Mixer Engine Lifecycle

Apollo Remote requires **UA Mixer Engine** to communicate with an Apollo.

When Apollo Remote starts, it launches the Universal Audio Mixer Engine executable:

```text
/Library/Application Support/Universal Audio/Apollo/UA Mixer Engine.app/Contents/MacOS/UA Mixer Engine
```

Apollo Remote does **not** launch UA Console.

### Engine Management

Apollo Remote manages the Mixer Engine session while the application is running:

* Starts UA Mixer Engine when needed
* Connects to the running engine
* Uses the engine for Apollo communication
* Monitors the connection
* Automatically reconnects when necessary
* Stops the Mixer Engine and associated mixer helper processes when Apollo Remote quits

Apollo Remote also takes ownership of the Mixer Engine lifecycle if the engine was already running when Apollo Remote launched. In that case, the engine and its associated mixer helper processes are still stopped when Apollo Remote exits.

> **Important:** Because Apollo Remote manages the Mixer Engine lifecycle, quitting Apollo Remote also terminates the Mixer Engine processes it manages.

## Project Structure

```text
Apollo-Remote/
├── ApolloRemote/                  # Main menu bar application
│   ├── ApolloRemoteApp.swift      # Application entry point
│   ├── AppDelegate.swift          # Menu bar setup and lifecycle
│   ├── MonitorView.swift          # Main popover UI
│   ├── SettingsView.swift         # Settings window
│   ├── AboutView.swift            # About window
│   └── Info.plist
│
├── ApolloRemoteWidget/            # WidgetKit extension
│   └── ApolloRemoteWidget.swift
│
├── Shared/                        # Shared application logic
│   ├── ApolloTCP.swift            # TCP client and message buffering
│   ├── ApolloController.swift     # State management and device control
│   ├── Models.swift               # Shared models and App Group constants
│   └── NetworkDiscovery.swift     # Bonjour network discovery
│
├── Assets.xcassets/               # Application assets
├── scripts/                       # Build and icon-generation scripts
├── Installer/                     # DMG installer assets
└── project.yml                    # XcodeGen configuration
```

## Troubleshooting

### "Connecting..." but Never Connects

* Make sure UA Mixer Engine is available on the target Mac.
* For remote connections, verify that the target Mac is reachable.
* Make sure both Macs are on the same network.
* Verify that TCP port `4710` is not blocked by a firewall.

### No Devices Found

* Make sure the Apollo is powered on.
* Verify that the Apollo is connected to the host Mac.
* Restart UA Mixer Engine if necessary.
* Reconnect Apollo Remote.

### Volume Changes Do Not Sync

Apollo Remote uses subscription-based updates rather than continuous polling.

If synchronization stops:

1. Click the reconnect button in the footer.
2. Verify that UA Mixer Engine is still running.
3. Reconnect to the selected host if necessary.

### Remote Connection Refused

* Make sure UA Mixer Engine is running on the remote Mac.
* Verify the remote Mac's IP address.
* Check that TCP port `4710` is accessible.
* Verify that macOS Firewall is not blocking the connection.
* Confirm both Macs are reachable on the network.

### Widget Not Updating

* Make sure Apollo Remote is running.
* The widget reads shared state from the application's App Group.
* Try removing and re-adding the widget.

## Credits

Protocol research and reference material:

* **[cuefinger](https://github.com/franqulator/cuefinger)** — protocol discovery
* **[UA-Midi-Control](https://github.com/raduvarga/UA-Midi-Control)** — additional protocol reference

Created by **[Noise Heroes](https://github.com/noiseheroes)**.

## License

MIT License — see [LICENSE](LICENSE) for details.

## Disclaimer

Apollo Remote is an **unofficial third-party application**.

Universal Audio, Apollo, and UA Console are trademarks of Universal Audio, Inc. Apollo Remote is not affiliated with, sponsored by, or endorsed by Universal Audio, Inc.
