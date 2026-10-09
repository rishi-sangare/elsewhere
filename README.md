# Elsewhere

**Change your iPhone's location for every app — Maps, WhatsApp, everything.**
Tap the map to teleport, or drive a route at your own speed with realistic traffic.
Free, open source, no jailbreak, no paid developer account.

> Status: **v0.1 — test builds.** Fully working in the iOS Simulator. The real-iPhone
> connection is implemented and compiles, and needs testers (see [docs/TESTING.md](docs/TESTING.md)).

## Features

- **Tap to teleport** anywhere; search places or paste coordinates / map links
- **Drive A → B** on real roads (Apple Maps routing, no API key) — walk, cycle, drive or any speed 1–200 km/h
- **Traffic**: none / light / moderate / heavy — slowdowns and red-light stops
- Realistic motion: accelerates, brakes, slows for corners, GPS-like wobble (still when parked)
- **Joystick** mode, favourites, recents, saved routes, GPX import/export
- **Fail-safe by design**
  - Green only when iOS *confirms* it's showing your chosen location
  - Alarm within seconds if your real location becomes visible
  - Notification if iOS kills the app ("dead-man switch")
  - Lock-screen / Dynamic Island status with a **Stop** button
  - Offers to resume after a crash or restart

## How it works

Elsewhere uses Apple's own developer location-simulation service (the one Xcode
uses), which changes the location system-wide. The app reaches the phone's
developer services through a local VPN loop (LocalDevVPN) using a one-time
pairing file. Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Install (iPhone, iOS 17.4+)

You need a computer **once** (~10 minutes). Full guide with screenshots: [docs/SETUP.md](docs/SETUP.md).

1. On a computer, install **[iLoader](https://github.com/nab138/iloader)**, connect your iPhone, install **SideStore** and save your **pairing file** (Manage Pairing File).
2. On the iPhone: **Settings → Privacy & Security → Developer Mode → On** (restart).
3. Install **[LocalDevVPN](https://apps.apple.com/app/id6755608044)** from the App Store and connect it.
4. In SideStore, add this source: `https://raw.githubusercontent.com/rishi-sangare/elsewhere/main/source.json` and install Elsewhere.
5. Open Elsewhere → import the pairing file → the setup checklist turns green.

After an iOS update, make a new pairing file (step 1).

## Develop

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
./scripts/fetch-idevice.sh        # device connection library (~210 MB, checksum-verified)
xcodegen generate
open Elsewhere.xcodeproj
```

**No iPhone? Use the Simulator as a "dummy iPhone".** Run the bridge on your Mac,
then run the app in the Simulator — it changes the Simulator's location for every
app inside it (open the Simulator's Maps to see):

```bash
python3 tools/sim-bridge.py --real 18.5204,73.8567
```

Stop the bridge mid-session to rehearse "connection lost".

Tests:

```bash
swift test --package-path Packages/SpoofKit   # engine + 400-scenario fault injection
python3 tools/design_sim.py                    # design-level simulation
```

## Project layout

| Path | What |
|---|---|
| `Packages/SpoofKit` | Pure-Swift engine: geo maths, route player, traffic, jitter, GPX, **session supervisor** (all safety logic) + tests |
| `App/Core` | `SpoofController` (orchestration), search |
| `App/Backends` | `SimulatorBridgeBackend`, `DVTBackend` (real iPhone via idevice), pairing & developer-image management |
| `App/Services` | Read-back verification, dead-man notifications, keep-alive, Live Activity, routing |
| `App/Views` | SwiftUI screens |
| `Widgets`, `Shared` | Live Activity |
| `tools` | Simulator bridge, design simulation |

## Responsible use

For privacy, testing and development on **your own device**. Some apps forbid
location spoofing in their terms — location-based games may ban accounts. Don't
use it to deceive people in ways that harm them. You're responsible for how you use it.

## Credits & licence

MIT. Device communication by [idevice](https://github.com/jkcoxson/idevice) (MIT).
Approach informed by [RouteSim](https://github.com/DasVR/RouteSim) (MIT) and
[pymobiledevice3](https://github.com/doronz88/pymobiledevice3). StikDebug (AGPL) code is not used.
