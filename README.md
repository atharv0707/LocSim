# LocSim

LocSim sets the GPS location of an iPhone from an app on the iPhone itself. You choose a place on a map in the LocSim app, and a small companion server running on a Mac applies that location to the phone using [pymobiledevice3](https://github.com/doronz88/pymobiledevice3). Once the app is installed, Xcode is not required to change the location.

## Contents

- [How it works](#how-it-works)
- [Features](#features)
- [Requirements](#requirements)
- [Repository layout](#repository-layout)
- [Setup](#setup)
  - [1. Clone the repository](#1-clone-the-repository)
  - [2. Prepare the iPhone](#2-prepare-the-iphone)
  - [3. Set up LocSimServer on the Mac](#3-set-up-locsimserver-on-the-mac)
  - [4. Build and install the iOS app](#4-build-and-install-the-ios-app)
  - [5. Connect the app to the server](#5-connect-the-app-to-the-server)
- [Running LocSimServer as a background service](#running-locsimserver-as-a-background-service)
- [Using the app](#using-the-app)
- [Networking](#networking)
- [Configuration](#configuration)
- [Server API](#server-api)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Development workflow](#development-workflow)

## How it works

LocSim has two parts:

```
+-------------------+       HTTP (port 8765)        +----------------------+    pymobiledevice3    +--------------+
|  LocSim app       |  --------------------------->  |  LocSimServer        |  -------------------> |  iPhone GPS  |
|  (on the iPhone)  |  Wi-Fi, hotspot or Tailscale   |  (Python, on a Mac)  |   cable or same LAN   |              |
+-------------------+                                +----------------------+                       +--------------+
```

1. The **LocSim app** (SwiftUI, iOS) lets you search for a place, paste coordinates or drop a pin, and sends the chosen coordinates to the server.
2. **LocSimServer** (Python, macOS) receives the request and runs `pymobiledevice3 developer dvt simulate-location set`, which makes iOS report the simulated location to every app on the phone. Stopping the simulation runs the matching `clear` command, and the phone returns to its real GPS.

An iOS app cannot change the device's location on its own. The change has to be made by a connected Mac through Apple's developer services, which is why the server is required.

## Features

- Place search with live suggestions (Apple Maps search, no API key required).
- Paste coordinates or a Google Maps link, or tap the map to drop a pin on an exact spot.
- One-tap start and stop, plus a Start button that resumes the last simulated location.
- Live status showing whether simulation is on, connecting or off, or whether the server is unreachable.
- The iPhone's own reported location is shown on the map, so you can confirm the simulated location has been applied.
- Favourites (with rename and delete) and a list of recent places.
- Find My-style bottom sheet with three heights.
- The server confirms each location with the phone before reporting success, and retries automatically if the phone disconnects.
- Optional background service, so the server starts at login and restarts if it stops.

## Requirements

| Component | Requirement |
| --- | --- |
| Mac | macOS with Xcode 26 or later installed |
| iPhone | iOS 26.5 or later, with Developer Mode enabled |
| Apple ID | A free Apple ID is sufficient for installing on your own device |
| Python | Python 3 (for example from Homebrew: `brew install python`) |
| pymobiledevice3 | Installed into the project's own Python environment (see setup) |
| Tailscale (optional) | Lets the app reach the server from other networks |

## Repository layout

```
LocSim/
├── LocSim/                       iOS app source (SwiftUI)
│   ├── LocSimApp.swift           App entry point
│   ├── ContentView.swift         Full-screen map, floating controls, bottom sheet host
│   ├── PanelView.swift           Bottom sheet: status, search, favourites, recents, settings
│   ├── LocSimModel.swift         App state, server status and saved places
│   ├── LocSimClient.swift        HTTP client for LocSimServer
│   ├── LocationSearch.swift      Apple Maps place search and suggestions
│   ├── LocationAccess.swift      Location permission request (for the map's location dot)
│   ├── Place.swift               Place model and coordinate parsing
│   └── Assets.xcassets           App icon and colours
├── LocSim-Info.plist             Additional Info.plist keys (network and location permissions)
├── LocSim.xcodeproj              Xcode project
├── LocSimServer/
│   ├── locsim_server.py          The server (Python standard library and pymobiledevice3)
│   └── install_service.sh        Installs or removes the background service (launchd)
├── .gitignore
└── README.md
```

## Setup

### 1. Clone the repository

```bash
git clone https://github.com/atharv0707/LocSim.git
cd LocSim
```

### 2. Prepare the iPhone

1. Connect the iPhone to the Mac with a cable, unlock it and tap **Trust** if prompted.
2. Open Xcode once with the iPhone connected so that it can prepare the device. Then, on the iPhone, go to **Settings > Privacy & Security > Developer Mode**, turn it on and restart when asked.

Developer Mode must remain enabled for location simulation to work.

### 3. Set up LocSimServer on the Mac

Create a private Python environment for the server and install pymobiledevice3 into it. A dedicated environment avoids the `externally-managed-environment` error that Homebrew's Python reports for system-wide installs.

```bash
python3 -m venv LocSimServer/.venv
LocSimServer/.venv/bin/python -m pip install -U pymobiledevice3
```

Start the server:

```bash
LocSimServer/.venv/bin/python LocSimServer/locsim_server.py
```

On start-up it prints the addresses the app can use, for example:

```
LocSimServer running. In the LocSim app (Settings), use one of:
     Atharvs-MacBook-Air.local:8765
     172.20.10.14:8765
     100.78.197.95:8765  (Tailscale)
```

If macOS asks whether Python may accept incoming network connections or find devices on the local network, choose **Allow**. Leave the Terminal window open while testing. Press `Ctrl+C` to stop the server; this also returns the phone to its real location.

To confirm that the Mac can reach the phone, you can run a one-off test. The phone's location should move to central London. Press `Ctrl+C` to end the test.

```bash
LocSimServer/.venv/bin/python -m pymobiledevice3 developer dvt simulate-location set --native -- 51.5072 -0.1276
```

### 4. Build and install the iOS app

1. Open `LocSim.xcodeproj` in Xcode.
2. Select the **LocSim** project in the navigator, then the **LocSim** target, then the **Signing & Capabilities** tab.
3. Tick **Automatically manage signing** and choose your **Team**. With a free Apple ID this is "Your Name (Personal Team)".
4. If you are not the original author, change the **Bundle Identifier** to something unique, for example `com.yourname.locsim`. Bundle identifiers must be unique across all Apple developers.
5. Choose your iPhone as the run destination at the top of the window and press **Run** (Command-R).
6. If the iPhone reports an untrusted developer, go to **Settings > General > VPN & Device Management**, select your Apple ID, tap **Trust**, then run again.

After installation, the app can be opened from the Home Screen and Xcode does not need to stay open. Apps signed with a free Apple ID expire after seven days; run the project from Xcode again to reinstall.

On first launch, allow **Local Network** access (needed to reach the server) and **Location** access while using the app (needed to show the phone's location on the map).

### 5. Connect the app to the server

1. In LocSim, tap the **Settings** (gear) button.
2. Enter one of the addresses printed by the server. See [Networking](#networking) for which one to use.
3. Tap **Test connection**. A successful test shows "Connected to LocSimServer".

## Running LocSimServer as a background service

Once everything works, you can keep the server running permanently. The service starts when you log in and restarts automatically if it stops.

```bash
./LocSimServer/install_service.sh              # install or reinstall
./LocSimServer/install_service.sh --uninstall  # remove
```

The installer uses `LocSimServer/.venv` automatically when it exists. Server output is written to `~/Library/Logs/LocSimServer.log`:

```bash
tail -f ~/Library/Logs/LocSimServer.log
```

The service runs as a LaunchAgent named `com.atharvtiwari.locsim`. A user must be logged in on the Mac, and the Mac must be awake.

## Using the app

| Action | How |
| --- | --- |
| Choose a place | Pull the sheet up and search, paste coordinates or a Google Maps link, or tap the map |
| Start simulating | Tap **Simulate here** on the selected place |
| Stop simulating | Tap **Off** next to the status |
| Resume the last place | Tap **Start** next to the status (disabled if no place has been simulated yet) |
| Save a favourite | Tap the star on the selected place, or swipe right on a recent place |
| Rename or remove a favourite | Swipe left on it, or press and hold for more options |
| Delete recents | Swipe left on a recent place, or tap **Clear** |
| Return the map to your location | Tap the location button in the top-right corner |

The status at the top of the sheet means:

| Status | Meaning |
| --- | --- |
| Simulating | The phone has confirmed the simulated location |
| Connecting to iPhone | The server has the request but cannot currently reach the phone; it retries every 15 seconds |
| Real location | Simulation is off |
| Mac not reachable | The app cannot contact LocSimServer at the configured address |

## Networking

There are two separate connections, and both must work:

1. **App to server (HTTP, port 8765).** The phone must be able to reach the Mac over the network.
2. **Server to iPhone (Apple developer services).** The Mac must be able to see the iPhone. macOS only finds an iPhone over a **USB cable** or on the **same local network**. This connection cannot be made over Tailscale or the internet.

Which address to enter in the app:

| Situation | Address |
| --- | --- |
| Phone and Mac on the same Wi-Fi | `<Mac name>.local:8765`, for example `Atharvs-MacBook-Air.local:8765` |
| Mac connected to the iPhone's Personal Hotspot | The `172.20.10.x:8765` address printed by the server (this can change between connections) |
| Tailscale installed and signed in on both devices | The Mac's Tailscale address, for example `100.78.197.95:8765` (does not change) |

Supported set-ups:

- Phone and Mac on the same Wi-Fi network.
- Mac connected to the iPhone's Personal Hotspot. Using the Tailscale address in the app is recommended, because the hotspot address can change.
- Phone connected to the Mac by cable. The phone can then be on any network if the app reaches the server over Tailscale.

Not supported: the phone on one network (for example mobile data) while the Mac is elsewhere, with no cable or shared local network between them. The app will reach the server over Tailscale, but the server cannot reach the phone, and the status will remain on "Connecting to iPhone".

## Configuration

### Server

LocSimServer is configured with environment variables:

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8765` | Port the HTTP server listens on |
| `PMD_ARGS` | `--native` on macOS | Connection options passed to pymobiledevice3. `--native` reaches the iPhone through macOS's own device connection (the one Xcode uses), which works over cable and Wi-Fi without root access |

Example:

```bash
PORT=9000 LocSimServer/.venv/bin/python LocSimServer/locsim_server.py
```

### App

| Setting | Where | Notes |
| --- | --- | --- |
| Server address | Settings (gear) in the app | Stored on the device; the port defaults to 8765 if omitted |
| App Transport Security | `LocSim-Info.plist` | `NSAllowsArbitraryLoads` is enabled so that the app can use plain HTTP to the server, including Tailscale `100.x.x.x` addresses. Do not add `NSAllowsLocalNetworking`: when it is present, iOS ignores `NSAllowsArbitraryLoads` and blocks Tailscale addresses |
| Bundle identifier | Xcode target settings | Change it if you are building under your own Apple ID |

## Server API

All responses are JSON.

| Method | Path | Body | Response |
| --- | --- | --- | --- |
| `GET` | `/status` (or `/`) | None | `{"active": bool, "message": str, "name": str, "lat": float, "lon": float}`; `name`, `lat` and `lon` are present only while a location is set |
| `POST` | `/set` | `{"lat": float, "lon": float, "name": str}` | `200` with `{"message": ...}` once the phone confirms the location; `500` with an explanation if the phone cannot be reached (the server keeps retrying in the background) |
| `POST` | `/clear` | `{}` | `200` with `{"message": ...}`; the phone returns to its real GPS |

Example:

```bash
curl -X POST http://localhost:8765/set -H 'Content-Type: application/json' \
     -d '{"lat": 51.5072, "lon": -0.1276, "name": "London"}'
curl http://localhost:8765/status
curl -X POST http://localhost:8765/clear -d '{}'
```

## Troubleshooting

| Problem | Cause and fix |
| --- | --- |
| `error: externally-managed-environment` when installing pymobiledevice3 | Homebrew's Python blocks system-wide installs. Use the project environment as shown in setup: create it with `python3 -m venv LocSimServer/.venv` and install with `LocSimServer/.venv/bin/python -m pip ...` |
| The server prints `pymobiledevice3 not found` | The server was started with the system `python3`. Start it with `LocSimServer/.venv/bin/python` |
| The app shows "Mac not reachable" or "The request timed out" | Check that the server is running, that the address in Settings matches one printed by the server, and that the two devices can reach each other (or that Tailscale is on for both). If the Mac is on the iPhone's hotspot, its hotspot address may have changed |
| The app shows "App Transport Security policy requires the use of a secure connection" | `LocSim-Info.plist` must contain `NSAllowsArbitraryLoads` and must not contain `NSAllowsLocalNetworking`. Rebuild the app after changing it |
| The status stays on "Connecting to iPhone", or the server logs "Device not found" | The Mac cannot see the phone. Connect it by cable, or put the Mac on the same Wi-Fi network or on the iPhone's hotspot. Make sure the phone is unlocked and Developer Mode is on |
| `pymobiledevice3 usbmux list` returns `[]`, or a command reports "Device is not connected" | The direct USB route is unavailable on recent macOS and iOS versions. LocSimServer uses `--native` by default, which works through macOS's own device connection |
| The location changes briefly, then reverts | Another tool, such as Xcode's Debug > Simulate Location, is also controlling the location. Quit Xcode or choose "Don't Simulate Location" while using LocSim |
| The app no longer opens after a week | Apps signed with a free Apple ID expire after seven days. Run the project from Xcode again |
| The location dot does not appear on the map | Allow location access for LocSim in **Settings > Privacy & Security > Location Services** |
| The Home Screen still shows an old icon | Delete the app from the phone and run it from Xcode again; iOS caches app icons |

## Security

- LocSimServer has no authentication. Anyone who can reach port 8765 on the Mac can change the phone's location. Only run it on networks you trust, such as your home network or your Tailscale network.
- The server listens on all network interfaces (`0.0.0.0`). Use the macOS firewall if you need to restrict access further.
- Keep the repository private if it contains personal network names or addresses.

## Development workflow

- Work on the `develop` branch and merge into `master` when a change is ready:

  ```bash
  git switch develop
  git add .
  git commit -m "Describe the change"
  git push
  ```

- The Xcode project uses a file-system synchronised group, so Swift files added to the `LocSim/` folder are included in the build automatically.
- The following are not committed (see `.gitignore`): the Python environment (`LocSimServer/.venv`), Xcode user data, build output and macOS metadata.
- When editing project files outside Xcode, close Xcode first, or keep the version on disk when Xcode asks. Otherwise, Xcode may save its in-memory copy over your changes.
