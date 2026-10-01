<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="Apollo Remote" width="128">
</p>

<h1 align="center">Apollo Remote</h1>

<p align="center">
  <strong>Control your Universal Audio Apollo from anywhere on your network.</strong>
</p>

<p align="center">
  <a href="https://github.com/noiseheroes/ApolloRemote/releases"><img src="https://img.shields.io/github/v/release/noiseheroes/ApolloRemote?style=flat-square" alt="Release"></a>
  <img src="https://img.shields.io/badge/macOS-14.0+-blue?style=flat-square" alt="macOS 14.0+">
  <img src="https://img.shields.io/badge/Swift-5.10-orange?style=flat-square" alt="Swift 5.10">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/noiseheroes/ApolloRemote?style=flat-square" alt="License"></a>
</p>

---

## Overview

Apollo Remote is a native macOS menu bar app for controlling Universal Audio Apollo monitor output. Works locally or remotely over your network — control volume, mute, dim, and mono from any Mac on your LAN.

No need to keep UA Console open on your screen. Just click the menu bar icon.

## Features

| Feature | Description |
|---------|-------------|
| **Volume Control** | Full range slider (-96 to 0 dB) with precision curve and real-time display |
| **Mac Volume Keys** | Remaps the keyboard's volume/mute keys to drive the Apollo directly (see below) |
| **Mute / Dim / Mono** | One-click toggles with visual feedback |
| **Network Control** | Connect to any Apollo on your LAN, not just localhost |
| **Auto-Discovery** | Automatically find UA Console instances via Bonjour |
| **Multi-Device** | Enumerate and select devices and outputs dynamically from protocol |
| **Real-time Sync** | Subscribe-based push updates — instant sync with hardware |
| **Auto-Reconnect** | Exponential backoff reconnection, auto-launches UA Mixer Engine |
| **macOS Widget** | WidgetKit widget shows volume, mute/dim/mono status at a glance |
| **Persistent Config** | Remembers last host, device, and output across restarts |
| **Native UI** | SwiftUI menu bar app, follows Apple HIG |
| **Zero Dependencies** | Built entirely with Apple frameworks |

## Requirements

- **macOS 14.0** (Sonoma) or later
- **Universal Audio Apollo** (Solo, Twin, x4, x6, x8, x8p, x16)
- **UA Console / UA Mixer Engine** running on the target Mac

## Installation

### Download

1. Download the latest `.dmg` from [Releases](https://github.com/noiseheroes/ApolloRemote/releases)
2. Open the DMG and drag **Apollo Remote** to **Applications**
3. **First launch:** Right-click the app → **Open** → **Open**

> **Note:** The app is not notarized. macOS will block it on first launch.
> Right-click → Open → Open. You only need to do this once.

### Build from Source

```bash
git clone https://github.com/noiseheroes/ApolloRemote.git
cd ApolloRemote
xcodegen generate    # requires: brew install xcodegen
open ApolloRemote.xcodeproj
```

Set your Development Team in Signing & Capabilities, then Build & Run.

## Usage

### Basic Controls

1. **Click the dial icon** in your menu bar
2. **Drag the slider** to adjust volume (-96 to 0 dB)
3. **Click Mute / Dim / Mono** to toggle
4. The panel closes when you click outside

### Remote Control

The app auto-discovers UA Console instances on your network. To connect to a remote Apollo:

1. Click the **gear icon** in the popover footer → **Settings**
2. Go to the **Connection** tab — remote hosts appear automatically
3. Click a host to connect, then choose your device and output
4. Done — you're controlling the Apollo remotely

You can also add hosts manually if auto-discovery doesn't find them.

### Mac Volume Keys

Apollo Remote can take over the keyboard's volume-up, volume-down, and mute
keys so they drive the Apollo's monitor level directly instead of the
(non-functional) system volume HUD.

This requires **Accessibility** permission — macOS only lets an app watch
system-wide key presses once you've explicitly approved it in **System
Settings → Privacy & Security → Accessibility**. Apollo Remote asks for this
automatically:

1. On first launch (the feature is on by default), macOS shows its own
   Accessibility permission prompt. Click **Open System Settings** and enable
   the toggle for Apollo Remote.
2. The app polls in the background and starts intercepting the keys the
   moment you flip that switch — no need to relaunch.
3. If you dismissed the prompt, or want to check the status later, open
   **gear icon → Settings → Keyboard** and click **Authorize…**.

If the keys still don't respond after granting permission, make sure the
Apollo is actually set as your Mac's **default output device** (System
Settings → Sound) — the keys only take over while the Apollo is what macOS
is currently playing through.

The mute / volume-down / volume-up keys are intercepted **directly** — no
Fn, no ⌘, no chord. They drive the Apollo monitor level and fully replace
Apple's greyed-out system volume HUD while the Apollo is the default output
device, whether or not "Use F1, F2, etc. keys as standard function keys" is
turned on in System Settings → Keyboard.

### Settings

Access settings from the gear icon in the popover footer.

| Tab | Options |
|-----|---------|
| **Connection** | Host auto-discovery, device/output pickers, manual host entry |
| **Keyboard** | Accessibility status, volume-key toggle, step size, mute-key behavior |
| **Audio** | Volume step size for keyboard shortcuts |
| **General** | Launch at login, version info |

### Widget

Apollo Remote includes a macOS widget (small and medium sizes) that shows your current volume level and mute/dim/mono status in real time.

## How It Works

The app communicates with UA Mixer Engine via TCP on port `4710`. This is the same internal protocol used by Universal Audio's own software.

```
Transport: TCP/IP
Port:      4710
Host:      Any Mac running UA Mixer Engine (local or remote)
Format:    JSON over null-terminated strings
Sync:      Subscribe-based push (not polling)
```

### Connection Flow

```
1. Connect TCP to host:4710
2. get /devices → enumerate available devices
3. get /devices/{id} → device name, online status
4. get /devices/{id}/outputs → enumerate outputs
5. subscribe to CRMonitorLevel, Mute, DimOn, MixToMono
6. Real-time push updates from UA Mixer Engine
```

### Protocol Commands

| Command | Example |
|---------|---------|
| `get` | `get /devices/0/outputs/4/CRMonitorLevel` |
| `set` | `set /devices/0/outputs/4/CRMonitorLevel/value/ -24.0` |
| `subscribe` | `subscribe /devices/0/outputs/4/Mute` |

## Project Structure

```
ApolloRemote/
├── ApolloRemote/              # Main menu bar app
│   ├── ApolloRemoteApp.swift  # App entry point
│   ├── AppDelegate.swift       # Menu bar setup & lifecycle
│   ├── MonitorView.swift       # Main popover UI (volume, controls, footer)
│   ├── SettingsView.swift      # Settings window (Connection/Audio/General)
│   ├── AboutView.swift         # About window
│   └── Info.plist
│
├── ApolloRemoteWidget/        # macOS Widget (WidgetKit)
│   └── ApolloRemoteWidget.swift
│
├── Shared/                     # Core logic (Models.swift shared with widget)
│   ├── ApolloTCP.swift         # TCP client with message buffering
│   ├── ApolloController.swift  # State management, enumeration, widget sync
│   ├── Models.swift            # UAHost, UADevice, UAOutput, App Group constants
│   └── NetworkDiscovery.swift  # Bonjour NWBrowser discovery
│
├── Assets.xcassets/            # App icon
├── scripts/                    # Build scripts, icon generator
├── Installer/                  # DMG background assets
└── project.yml                 # XcodeGen configuration
```

## Troubleshooting

### "Connecting..." but never connects

- Make sure **UA Console** or **UA Mixer Engine** is running on the target Mac
- For remote: verify the target Mac's IP and that port 4710 is accessible
- Check that both Macs are on the same network/subnet

### No devices found after connecting

- The Apollo must be powered on and connected to the host Mac
- Try restarting UA Mixer Engine on the host Mac

### Volume changes don't sync from hardware

- The app uses `subscribe` for real-time push updates
- If sync stops, click the reconnect button in the footer

### Remote connection refused

- UA Mixer Engine must be running on the remote Mac
- Ensure no firewall is blocking port 4710
- Try pinging the remote Mac to verify network connectivity

### Widget not updating

- Make sure the main app is running — the widget reads data shared via App Group
- Try removing and re-adding the widget

## Credits

- Protocol discovery by **[cuefinger](https://github.com/franqulator/cuefinger)** ([@franqulator](https://github.com/franqulator))
- Additional protocol reference from **[UA-Midi-Control](https://github.com/raduvarga/UA-Midi-Control)** ([@raduvarga](https://github.com/raduvarga))
- Created by [Noise Heroes](https://github.com/noiseheroes)

## License

MIT License — see [LICENSE](LICENSE) for details.

## Disclaimer

This is an **unofficial third-party application**. Universal Audio, Apollo, and UA Console are trademarks of Universal Audio, Inc. This project is not affiliated with or endorsed by Universal Audio.


## UAD Mixer Engine lifecycle

ApolloRemote starts the Universal Audio Mixer Engine executable before connecting:

`/Library/Application Support/Universal Audio/Apollo/UA Mixer Engine.app/Contents/MacOS/UA Mixer Engine`

UA Console is not launched. ApolloRemote owns the Mixer Engine session while it is running and stops the engine and its mixer helper processes when the app quits, including an engine that was already running at launch.
