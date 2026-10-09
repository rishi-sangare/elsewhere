# Elsewhere: Architecture & Design Report

> **Working name:** *Elsewhere* (easy to rename later).
> **What it is:** a free, open-source iPhone app that changes the location every app on the phone sees (Google Maps, WhatsApp, Find My, everything) by tapping a map or "driving" a route at a chosen speed with simulated traffic.
> **Status:** design approved; implementation next.
> **Date:** 2026-10-10

---

## 0. One-page summary

| Question | Answer |
|---|---|
| Does it work for **all apps**? | Yes. It uses Apple's own developer location-simulation service, which overrides the location for the whole system. |
| Jailbreak? | No. |
| Paid Apple developer account? | No. A free Apple ID works (SideStore re-signs the app every 7 days). |
| Computer needed? | **Once, about 10 minutes**, to install SideStore and create a *pairing file*. After that, only the iPhone. |
| App Store? | No. Apple doesn't allow apps that use these developer services. Users install from GitHub through SideStore. |
| Minimum iOS | **17.4** |
| Language / UI | Swift + SwiftUI + Apple MapKit (no map API keys, no server) |
| Device library | [`idevice`](https://github.com/jkcoxson/idevice) (Rust, MIT) via its official Swift XCFramework |
| License | **MIT**. We write our own bridge against `idevice` and do **not** copy StikDebug code, which is AGPL. |
| Biggest risk | Nobody on the team has an iPhone. The device layer must be verified by testers (Section 11). |

---

## 1. How it works

```
┌──────────────────────────────── iPhone ─────────────────────────────────┐
│                                                                          │
│   Elsewhere app                                                          │
│   ┌──────────────┐   fixes @1 Hz   ┌───────────────┐                     │
│   │ Motion engine│ ──────────────► │ DeviceSession │  idevice (Rust FFI)  │
│   │ (teleport,   │                 │ serial queue  │──────────┐           │
│   │  route, joy) │ ◄── state ───── │ + watchdog    │          │           │
│   └──────────────┘                 └───────────────┘          │           │
│          ▲                                                    ▼           │
│          │ read-back (are we really spoofed?)       10.7.0.1:49152        │
│   ┌──────────────┐                                           │           │
│   │ TruthMonitor │◄── CLLocationManager           LocalDevVPN (loopback)  │
│   └──────────────┘          ▲                                 │           │
│                             │                                 ▼           │
│                             │                RemotePairing → RSD tunnel   │
│                             │                → mount Developer Disk Image │
│                             │                → DVT LocationSimulation     │
│                             │                                 │           │
│                       ┌─────┴─────────────────────────────────▼───────┐   │
│                       │ locationd: the ONE location source for iOS     │   │
│                       └───┬──────────┬──────────┬──────────┬──────────┘   │
│                        Google     WhatsApp   Find My    any app          │
│                         Maps                                              │
└──────────────────────────────────────────────────────────────────────────┘
```

The chain, step by step. These are the same calls RouteSim/StikDebug make and that `idevice` provides:

1. **Pairing file** (`rp_pairing_file_read`). A trust record made once on a computer. It lets our app log in to the phone's own developer services, the way a trusted Mac would.
2. **LocalDevVPN** (free, App Store) creates a loopback network. The phone's developer services appear at `10.7.0.1`, so the app can connect to its own phone.
3. **Tunnel** (`tunnel_create_rppairing`, port 49152). An encrypted RemotePairing tunnel, followed by an RSD handshake that lists the available services.
4. **Developer Disk Image (DDI)** (`image_mounter_mount_personalized…`). Apple's developer tools package. It's downloaded once, personalized for this phone by Apple's signing server, mounted, and cached. It stays mounted until the phone restarts.
5. **DVT LocationSimulation** (`remote_server_connect_rsd`, `location_simulation_new`, then `location_simulation_set(lat, lon)` and `location_simulation_clear`). This is the actual spoof.

**Important technical fact:** the service only accepts **latitude and longitude**. iOS works out *speed* and *direction* from how far apart successive points are and how often they arrive. All realism therefore comes from **what we send and when** (Section 6).

---

## 2. User setup flow (what the README tells people)

### Part A: on a computer, once (Mac, Windows or Linux)
1. Install **iLoader** (free; installs SideStore and manages pairing files).
2. Plug in the iPhone and tap **Trust**.
3. In iLoader, sign in with your **own** Apple ID and install **SideStore**. Your Apple ID is sent only to Apple; Elsewhere never sees it.
4. In iLoader, open **Manage Pairing File** and **export/place** the pairing file. If iLoader can place it directly into Elsewhere, use that; otherwise save it and AirDrop it to the phone.

> Note: the computer **does not** switch Developer Mode on. It installs SideStore and creates the pairing file. Developer Mode is switched on in the phone's Settings (step 5).

### Part B: on the iPhone
5. **Settings → Privacy & Security → Developer Mode → On**, then restart. The toggle appears after any sideloaded app is installed. Sideloaded apps won't even open without it.
6. Install **LocalDevVPN** from the App Store.
7. In SideStore, **add our app list URL** and install **Elsewhere**.
8. Open Elsewhere. The **Setup Wizard** checks everything (Section 8.1) and tells you exactly what to fix.

**Ongoing:** keep SideStore's 7-day auto-refresh on. After **any iOS update**, create a new pairing file (repeat step 4); the app detects this and explains it.

---

## 3. Features (v1.0 scope)

| # | Feature | Description |
|---|---|---|
| F1 | **Tap to teleport** | Tap anywhere, a pin drops, then **Teleport here**. Also long-press, search, or paste coordinates or a Google Maps link. |
| F2 | **A → B route** | Pick start and end (or several stops). Apple Maps calculates a real road route on the phone. |
| F3 | **Speed** | Walk 5 / Cycle 15 / Drive 40 / Custom (1–200 km/h slider). |
| F4 | **Traffic** | None / Light / Moderate / Heavy: slow stretches plus red-light stops (Section 6.3). |
| F5 | **Playback** | Play, pause, stop, scrub, 1×/2×/5×, loop, back-and-forth, ETA and live speed display. |
| F6 | **Joystick** | Move freely at walk or drive speed with an on-screen stick. |
| F7 | **Places** | Favourites, recents, saved routes; GPX import/export. |
| F8 | **Status everywhere** | Status pill, Live Activity and Dynamic Island with a Stop button, notifications. |
| F9 | **Setup Wizard & Diagnostics** | Live checklist, one-tap fixes, exportable log. |
| F10 | **Safety** | Verified-status indicator, exposure alarm, dead-man notification, auto-stop timer (Section 7). |

Out of scope for v1: Android, a Mac companion app, multiple devices, cloud sync, accounts.

---

## 4. Screens & UX

```
┌──────────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────────┐
│ ● SPOOFING · verified    │   │  Route                    │   │ ● DRIVING · 38 km/h      │
│ 🔍 Search places          │   │  A  Current fake location │   │                          │
│                          │   │  B  Mumbai Airport T2      │   │     (map follows car)    │
│        (full map)        │   │  ─────────────────────── │   │                          │
│            📍            │   │  🚶 🚲 🚗 ⚙︎  [ 40 km/h ]  │   │  ▓▓▓▓▓▓░░░░░  4.1/9.8 km │
│                          │   │  Traffic: ○ ● ○ ○  Light  │   │  ETA 11:42 · 14 min left │
│╭────────────────────────╮│   │  ☐ Loop  ☐ Return trip    │   │  ⏸  ⏹   1× 2× 5×         │
││ Gateway of India        ││   │  ~ 18 min · 9.8 km        │   │                          │
││ [Teleport] [Route] [☆] ││   │  [      Start drive     ] │   │  🕹 joystick (optional)   │
│╰────────────────────────╯│   └──────────────────────────┘   └──────────────────────────┘
└──────────────────────────┘
   Map / Teleport                  Route planner                   Now playing
```

- **One main screen** (a full-screen map) with a swipe-up bottom sheet in three heights. Other screens: Places, Setup/Diagnostics, Settings.
- **Status pill colours**, the single most important UI element:
  - ⚪ **Real location**
  - 🟡 **Connecting…** / **Reconnecting…**
  - 🟢 **Spoofing · verified** (only after the read-back confirms it; see 7.2)
  - 🔴 **Lost: your real location may be visible** (tap for the reason and a fix)
- **Stop** is always one tap away: on the pill, in the Live Activity, and in the notification.
- Haptics on teleport, start, stop and loss. Supports dark mode, Dynamic Type and VoiceOver labels.

---

## 5. Software architecture

### 5.1 Layers

```
App (SwiftUI)          Features: Map · Route · Playback · Joystick · Places · Setup · Settings
   │                   ViewModels are @Observable, @MainActor
   ▼
SpoofController        one actor = single source of truth for the session state machine
   │        ▲
   ▼        │ events
SpoofKit (pure Swift,  MotionEngine · RoutePlanner · TrafficModel · JitterModel ·
 no UIKit, unit-tested)  GeoMath · GPX · SessionStateMachine · Clock (injectable)
   │
   ▼
LocationBackend  (protocol)
   ├── DVTBackend        real iPhone: idevice FFI on one serial queue
   ├── SimulatorBackend  dev only: writes fixes to a file; host script drives `simctl location`
   └── MockBackend       unit tests: scriptable faults (drop, delay, reject)
   │
Services   TruthMonitor · DeadManSwitch · KeepAlive · DDIManager · PairingStore ·
           PreflightChecker · LiveActivityController · Persistence (SwiftData) · Logger
```

### 5.2 Key interfaces (sketch)

```swift
protocol LocationBackend: Sendable {
    func preflight() async -> [PreflightIssue]          // empty = ready
    func connect() async throws                          // tunnel + DDI + DVT
    func send(_ fix: Coordinate) async throws            // ~1 Hz
    func clear() async throws                            // back to real GPS
    func disconnect() async
}

struct Fix { let coordinate: Coordinate; let simTime: TimeInterval; let speed: Double }

protocol MotionSource {                                   // Teleport, RoutePlayer, Joystick
    mutating func next(at t: TimeInterval) -> Fix?       // nil = finished
}
```

- **All FFI calls go through one serial queue.** The C library isn't thread-safe, and only one location session may be open at a time.
- The **clock is injectable**, so engine tests run 30-minute drives in milliseconds.
- `SimulatorBackend` lets the whole app run in the iOS Simulator before any device exists. A small host script (`tools/sim-bridge`) reads the app's fix stream and calls `xcrun simctl location booted set lat,lon`, so we can watch Apple Maps in the Simulator follow the route.

### 5.3 Repository layout

```
elsewhere/
├─ App/                         Xcode app target (SwiftUI)
│  ├─ Features/{Map,Route,Playback,Joystick,Places,Setup,Settings}/
│  ├─ Services/{TruthMonitor,DeadManSwitch,KeepAlive,LiveActivity,…}.swift
│  └─ Resources/
├─ Widgets/                     Live Activity (optional target, see A7)
├─ Packages/
│  ├─ SpoofKit/                 pure Swift package + tests (runs on macOS CI)
│  └─ DeviceKit/                LocationBackend + DVTBackend (idevice wrapper)
├─ Vendor/IDevice.xcframework   pinned idevice release, checksum-verified
├─ tools/
│  ├─ design_sim.py             design-validation simulations (this report, Section 10)
│  └─ sim-bridge.sh             Simulator location bridge for development
├─ .github/workflows/
│  ├─ test.yml                  SpoofKit unit tests on every PR
│  └─ release.yml               build unsigned IPA → GitHub Release → update source.json
├─ source.json                  SideStore/AltStore app list
├─ docs/  ARCHITECTURE.md · SETUP.md (with screenshots) · TROUBLESHOOTING.md · TESTING.md
├─ LICENSE (MIT) · NOTICE (idevice credit) · README.md
```

### 5.4 Data (SwiftData, on-device only)

`Place(name, lat, lon, createdAt, isFavourite)` · `SavedRoute(name, waypoints[], polyline(encoded), mode, speedKmh, traffic, loop)` · `HistoryItem(placeRef, usedAt)` · `SessionIntent(active, mode, target, routeProgress, startedAt)`. `SessionIntent` is written to disk so the app can recover after a crash (7.5).

---

## 6. Motion engine

### 6.1 Route
- **Directions:** `MKDirections` (free, on-device, no API key). Car and walking modes; cycling uses the walking route at cycling speed. If offline, it falls back to a straight line or an imported GPX.
- **Densify:** resample the route to about 1 m spacing and track position as distance travelled along it. This makes progress, scrubbing and resuming exact.

### 6.2 Speed control (runs at 20 Hz internally, sends 1 Hz)
- **Target speed** = min(user speed × congestion factor, cornering limit √(a_lat · R), braking curve √(2 · b · distance_to_next_stop)).
- Car profile: accelerate 2.0 m/s², brake 2.5 m/s², cornering 2.0 m/s². Walk and cycle have their own profiles.
- A backward pass over the route sets the corner speed limits, so the car **slows down before** a turn, not during it.

### 6.3 Traffic model
| Level | Slow-down depth | Chance of stopping at an intersection | Stop length |
|---|---|---|---|
| None | 0% | 0% | – |
| Light | up to 20% | 15% | 5–20 s |
| Moderate | up to 45% | 35% | 10–45 s |
| Heavy | up to 70% | 55% | 20–75 s |

- Congestion is **smooth noise along the route** (about 600 m wavelength), so traffic thickens and clears gradually instead of flickering.
- Intersections come from MapKit route steps (each turn instruction is a junction).
- With a fixed **seed**, the same route replays identically for testing; it's random otherwise.

### 6.4 GPS jitter
- **While moving:** correlated noise (AR(1), ρ≈0.95, about ±3 m).
- **While parked:** jitter frozen or drifting very slowly.
- The simulation (Section 10.3) shows random-per-tick noise makes a *parked* phone appear to move at around 18 km/h. Correlated noise fixes most of that, and freezing it at 0 km/h fixes the rest.

### 6.5 Teleport and holding still
- Teleport sends the point immediately, then **re-sends the same point every 1 s** (heartbeat). RouteSim's notes show iOS falls back to real GPS if the fix isn't refreshed (Assumption A1).
- Optional **"travel there instead"**: drive or walk to the new spot rather than jumping. Useful when an app treats a sudden jump as suspicious.

---

## 7. Fail-safe design

**Principle:** we cannot stop iOS from going back to your real location. What we *can* guarantee is that **the app never says you're hidden when you're not, and you're told quickly when you're exposed.** The approach is *fail loud, never fail silent*.

### 7.1 Session state machine

```
           start                tunnel+DDI+DVT ok         read-back matches
  IDLE ──────────► PREFLIGHT ──────────► CONNECTING ──────────► ACTIVE (🟢 verified)
   ▲                  │ issue                │ fail                 │  ▲
   │                  ▼                      ▼                send fails / mismatch
   │            NEEDS_SETUP (wizard)   RECONNECTING (🟡) ◄──────────┘  │ success
   │                                         │ backoff 0.5,1,2,4,8 s ──┘
   │  stop / clear                           │ exposed > 5 s (ANY state)
   └──────────── STOPPING ◄──────────────── LOST (🔴 + alert, keeps retrying)
```

- Route progress is **frozen while not ACTIVE**, so after reconnecting there's no sudden jump that looks like 900 km/h.
- **Stop** always works. If the connection is alive, we send `clear`. If it's dead, iOS has already gone back to the real location. Either way the read-back confirms "real" before the pill turns ⚪.

### 7.2 TruthMonitor (verified status)
Our app runs its own `CLLocationManager`. Because the spoof is system-wide, **our own app sees exactly what WhatsApp sees.** The pill turns 🟢 only if the location iOS reports matches what we sent (within 25 m) during the last 3 s. This is the core safety mechanism. We never trust "the call didn't fail"; we check the result.

### 7.3 Exposure alarm
If the user wants spoofing but the read-back has shown the real location for more than **5 s**, *in any state*, the app shows the 🔴 pill, plays a haptic, posts a local notification ("Real location may be visible"), and updates the Live Activity.

### 7.4 Dead-man switch (if iOS kills the app)
A killed app can't warn anyone. So on every heartbeat we **re-schedule a local notification 10 s in the future**. While the app is alive it keeps postponing it. If iOS kills the app, the notification fires on its own: *"Elsewhere stopped — your real location is visible. Tap to resume."*

### 7.5 Crash and relaunch recovery
`SessionIntent` is saved to disk. On launch, if it says "active" but we aren't connected, we show: *"Spoofing stopped while the app was closed. Resume at <place>?"*

### 7.6 Pre-flight checks (before every start)
Each check has a plain-language fix:
1. Pairing file present, readable and for *this* phone.
2. LocalDevVPN connected (TCP test to 10.7.0.1:49152 with a 2 s timeout).
3. Developer Mode (implied by the app running, since sideloaded apps can't open without it).
4. DDI mounted, or mountable (needs internet the first time).
5. Location permission set to *Always* (needed for read-back and background).
6. Warnings: Low Power Mode on, battery under 15%, Background App Refresh off.

### 7.7 Background keep-alive
While a session is active, the app uses:
- **Background location** (`allowsBackgroundLocationUpdates`), which also feeds the TruthMonitor,
- **Silent audio** (Settings toggle, default on), resumed automatically after interruptions such as a phone call,
- `beginBackgroundTask` around reconnects.

Keep-alive stops as soon as the session stops.

### 7.8 Privacy & security
- The **pairing file is effectively a key to the phone.** It stays in the app container with `NSFileProtectionComplete`, is excluded from backups, is never uploaded, and is never written to logs.
- **Only these network connections:** Apple MapKit (maps, search, directions), Apple's signing server plus a pinned DDI download (checksum-verified, then cached). No analytics, no accounts, no servers of our own.
- Logs stay on-device and can be exported with coordinates masked.

---

## 8. Failure scenarios walked through

What happens in each scenario, and what the user sees:

| # | Scenario | What iOS does | What Elsewhere does | User sees |
|---|---|---|---|---|
| S1 | First launch, no pairing file | – | Pre-flight fails | Wizard: "Import pairing file", with a link to the guide |
| S2 | Pairing file from another phone, or old after an iOS update | Tunnel refused | Tunnel error mapped to cause | "Pairing file expired (iOS was updated). Make a new one: 2-min guide" |
| S3 | LocalDevVPN off, or another VPN took over | 10.7.0.1 unreachable | Pre-flight / TCP probe fails | "Turn on LocalDevVPN" + button to open it |
| S4 | First use, no internet | Can't personalize DDI | DDIManager error | "Needs internet once to download Apple's developer files" |
| S5 | DDI already mounted | – | Skips mount | Nothing (faster start) |
| S6 | Teleport, happy path | locationd uses fake fix | Heartbeat 1 Hz; read-back confirms | 🟢 within ~2 s |
| S7 | User switches to WhatsApp or Maps | App backgrounded | Keep-alive keeps heartbeat running | Live Activity stays 🟢 |
| S8 | Screen locked mid-route | – | Keep-alive; engine keeps driving | Lock-screen Live Activity shows speed and ETA |
| S9 | Tunnel drops randomly | Real location after a few s (A1) | Send fails, RECONNECTING; route paused; backoff | 🟡 briefly, then 🟢 |
| S10 | VPN down for minutes | Real location | Retries; after 5 s exposure, LOST + alert | 🔴 + notification, auto-recovers when VPN returns |
| S11 | iOS kills the app (memory) | Real location | Dead-man notification fires ≤10 s later | "Elsewhere stopped — real location visible" |
| S12 | Phone call or music takes audio | Silent audio interrupted | Location keep-alive continues; audio resumes after | Nothing |
| S13 | Low Power Mode | More aggressive background limits | Warns at start | Yellow warning chip |
| S14 | Phone restarts | Spoof gone, DDI unmounted | Next launch: recovery prompt; re-mount | "Spoofing stopped (restart). Resume?" |
| S15 | Forgot it's on | – | Optional auto-stop timer; persistent Live Activity | Reminder notification |
| S16 | SideStore certificate expired (7 days) | App won't open | (Can't run) | Docs: keep SideStore auto-refresh on |
| S17 | No internet during route | Maps tiles may be missing | Route already densified and in memory, keeps going | Route continues |
| S18 | Stop pressed while disconnected | Already real | Read-back confirms real | ⚪ "Real location" |
| S19 | Two apps both try to simulate (StikDebug + us) | Only one session allowed | Detect error, explain | "Another app is controlling location" |
| S20 | iOS 27.x changes the services | Calls fail | Version-aware error, link to issue tracker | "Not yet supported on iOS X — check for update" |

---

## 9. Distribution & build

- **GitHub repo** (MIT). Each tag runs `release.yml` on a macOS runner:
  1. download the pinned `IDevice.xcframework` and verify its checksum
  2. `xcodebuild archive` with signing disabled
  3. package `Elsewhere.ipa`
  4. attach it to a GitHub Release
  5. update `source.json`
- **`source.json`** (AltStore/SideStore source format): users add one URL and get updates in SideStore.
- People can also download the `.ipa` from Releases and install it with any sideloading tool.
- **iLoader integration (nice-to-have):** open a PR to iLoader so "Place pairing file" can target Elsewhere directly.

---

## 10. Design simulation results

`tools/design_sim.py` models **our design under our assumptions** (it does not model iOS), injects faults, and checks the safety rules. Full output: `tools/design_sim_output.txt`.

### 10.1 Session safety: 5,000 random 15-minute sessions
Faults injected: tunnel drops about every 3 minutes, VPN outages in 40% of sessions, app killed in 25%.

| Safety rule | Naive design | **Elsewhere design** |
|---|---|---|
| I1: longest "🟢" shown while phone actually showed the **real** location | 0.5 s | 1.0 s (read-back lag) |
| I2: longest the real location was exposed **without the user being told** | **894 s** | **10.5 s** |
| Sessions where the user wasn't told for > 15 s | 4,939 / 5,000 | **0 / 5,000** |
| I3: "🟢" after Stop | 0 s | 0 s |

**The simulation caught a real design bug.** In the first version, the exposure alarm only ran in the ACTIVE state, so during long reconnect attempts users could be exposed for 18 s without a warning. The fix, now in Section 7.3, is that the alarm runs in *every* state. The remaining 10.5 s worst case is the dead-man notification delay when iOS kills the app. That's an accepted limit, and it can be tuned down to about 5 s.

### 10.2 Motion engine: 8 km city route at 40 km/h

| Traffic | Trip time | Avg speed | Max speed | Max accel | Red-light stops |
|---|---|---|---|---|---|
| None | 12.6 min | 38.2 km/h | 40.0 | 2.5 m/s² | 0 |
| Light | 15.0 min | 32.2 km/h | 39.3 | 2.6 m/s² | 4 |
| Moderate | 18.3 min | 26.4 km/h | 38.4 | 2.5 m/s² | 6 |
| Heavy | 31.4 min | 15.4 km/h | 37.5 | 2.5 m/s² | 15 |

Speed never goes above what the user picked, braking stays at normal-car levels, and heavy traffic about 2.5× the trip time. That is believable city driving. (The first run of this simulation also found a bug where cars never pulled away from a red light; fixed.)

### 10.3 GPS jitter
Random ±3 m noise per tick makes a **parked** phone look like it's moving at about 18 km/h (95th percentile 38 km/h). Correlated noise brings that to about 4 km/h, which is why the design **freezes jitter when parked** (6.4).

---

## 11. Assumption register (what we believe vs. what's proven)

| ID | Assumption | Confidence | Evidence | How a tester verifies |
|---|---|---|---|---|
| A1 | iOS drops the fake location if the session closes or isn't refreshed for several seconds | Medium | RouteSim re-sends every ~4 s while paused "so iOS does not revert" | T3: kill app → time until Maps shows real |
| A2 | Our own `CLLocationManager` receives the spoofed location (read-back works) | High | Spoof is system-wide (locationd) | T2: compare app's read-back with Maps |
| A3 | Background keep-alive survives ≥ 1 hour with screen locked | Medium | RouteSim and StikDebug ship this | T5: 60-min locked drive |
| A4 | Works on mobile data with no Wi-Fi | **Unknown** | StikDebug troubleshooting mentions Wi-Fi | T6: Wi-Fi off, start spoof |
| A5 | Works on iOS 26 and 27 | Medium | StikDebug: "26.0+ supported, limited"; idevice updated 2026-10-08 | T1 on each OS version |
| A6 | `idevice` call chain (rppairing → RSD → DVT) is stable | High | Used in production by StikDebug and RouteSim | T1 |
| A7 | Free Apple ID can sign the Live Activity extension (App ID limits) | Medium | Free accounts allow 10 App IDs per 7 days | T8: install via SideStore |
| A8 | iLoader can place a pairing file into our app | Unknown | It supports a list of known apps | Manual import fallback ships anyway |

**Device test plan (`docs/TESTING.md`)**
- T1: setup from scratch
- T2: teleport and verify in Maps and WhatsApp
- T3: kill the app
- T4: 10 min route with traffic
- T5: 60 min locked
- T6: no Wi-Fi
- T7: turn VPN off mid-route
- T8: restart phone
- T9: stop, then confirm the real location returns

Each tester fills in a GitHub issue template.

---

## 12. Build plan (milestones)

| Milestone | Deliverable | Done when | Testable without an iPhone? |
|---|---|---|---|
| **M0** Foundation | Repo, Xcode project, SpoofKit package, CI (`test.yml`, unsigned IPA build) | CI is green and produces an `.ipa` | ✅ |
| **M1** Engine | GeoMath, densify, speed control, traffic, jitter, GPX, state machine; port the simulation invariants to XCTest | 100+ unit tests pass, including the I1–I3 fault tests | ✅ |
| **M2** UI | Map/teleport, route planner, playback, joystick, places, settings, using SimulatorBackend | Watch a 40 km/h drive in the iOS Simulator's Maps | ✅ |
| **M3** Device | DVTBackend (idevice), PairingStore, DDIManager, Setup Wizard, TruthMonitor | Tester passes T1, T2, T9 | ❌ tester |
| **M4** Safety & background | Keep-alive, dead-man switch, recovery, Live Activity | Tester passes T3–T8 | ❌ tester |
| **M5** Release | README, SETUP guide with screenshots, `source.json`, v1.0 release | A new user installs from the README alone | ✅ + tester |

---

## 13. Responsible use (goes in the README)

Elsewhere is for privacy, testing, and development on **your own device**. Some apps forbid location spoofing in their terms (location-based games ban accounts for it). Don't use it to deceive people in ways that harm them. You are responsible for how you use it.

---

## 14. References
- idevice (MIT): https://github.com/jkcoxson/idevice
- RouteSim (MIT, read for reference): https://github.com/DasVR/RouteSim
- StikDebug (AGPL; not copied): https://github.com/StephenDev0/StikDebug
- LocalDevVPN: https://apps.apple.com/app/id6755608044
- Pairing-file guide (iLoader): https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md
- pymobiledevice3 (protocol reference): https://github.com/doronz88/pymobiledevice3
- Personalized DDI mirror: https://github.com/doronz88/DeveloperDiskImage

---

## 15. Findings from Simulator testing (2026-10-10)

Built M0–M4 and exercised them in the iOS 27 Simulator, using `tools/sim-bridge.py` as a stand-in iPhone.

| Verified in Simulator | Result |
|---|---|
| Teleport changes location for **other apps** (Apple Maps) | ✅ |
| Route on real roads, 40 km/h, moderate traffic, red-light stops | ✅ |
| Apple Maps follows the moving fake location | ✅ |
| App killed → dead-man notification; bridge reverts like iOS | ✅ |
| Relaunch → "stopped while closed" banner → Resume | ✅ |
| Live Activity on lock screen with Stop button | ✅ |
| Real-iPhone backend (idevice) compiles and links | ✅ (runtime needs a tester) |

Design changes the testing forced:

1. **iOS reports location only when it changes.** At a fixed spot, iOS goes quiet, and the first supervisor treated silence as "not confirmed" (a false alarm). It now judges **the latest report**. If that's our location, the status stays green. A report of anywhere else turns it red immediately, with no grace window. Both cases are unit-tested, and the fault-injection run now delivers read-backs only on change.
2. **iOS pauses location updates while a permission prompt is showing.** That looks like exposure, so the "Always" permission is now requested during onboarding and never mid-session.
3. Taps on the bottom panel could fall through to the map and drop a pin. The map now ignores taps under the top bar and the bottom panel.
