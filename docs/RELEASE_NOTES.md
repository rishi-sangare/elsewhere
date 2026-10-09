## Elsewhere v0.1.0 — first test build

> ⚠️ **Pre-release.** Everything below is verified in the iOS Simulator. The real-iPhone
> connection is implemented but **not yet confirmed on a device** — testers wanted!
> Please run the checks in [docs/TESTING.md](https://github.com/rishi-sangare/elsewhere/blob/main/docs/TESTING.md) and open an issue with your results.

### What's in it
- **Tap to teleport** — search places or paste coordinates / map links
- **Drive A → B** on real roads at any speed, with **traffic** (none / light / moderate / heavy) and red-light stops
- **Joystick**, favourites, recents, saved routes, GPX import/export
- **Fail-safe:** green only when iOS confirms the location; alarm within seconds if your real location shows; notification if iOS kills the app; resume after a crash
- **Lock screen & Dynamic Island** status with a Stop button

### Install (iPhone, iOS 17.4+)
Follow [docs/SETUP.md](https://github.com/rishi-sangare/elsewhere/blob/main/docs/SETUP.md): a one-time ~10 min setup on a computer (iLoader → SideStore + pairing file), Developer Mode, LocalDevVPN. Then either add the SideStore source
`https://raw.githubusercontent.com/rishi-sangare/elsewhere/main/source.json`
or sideload `Elsewhere.ipa` below. Verify the download with `Elsewhere.ipa.sha256`.

### Known limitations
- Unconfirmed on real devices; mobile-data-only (no Wi-Fi) behaviour unknown
- No app icon yet
- After any iOS update, make a new pairing file

For privacy, testing and development on your own device. Some apps forbid location spoofing in their terms.
