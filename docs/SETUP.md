# Setting up Elsewhere

About 10 minutes, once. You need a Mac, Windows or Linux computer and a USB cable
for the first part only.

## Part A — on a computer (once)

1. Download and install **iLoader** from <https://github.com/nab138/iloader/releases>
   (Windows: install Apple's iTunes first; Linux: needs `usbmuxd`).
2. Plug in your iPhone, unlock it, tap **Trust**.
3. In iLoader, sign in with **your own Apple ID** (it's sent only to Apple) and install **SideStore**.
4. In iLoader open **Manage Pairing File** and save/export the pairing file
   (if Elsewhere is listed there, **Place** puts it straight into the app).
   Otherwise AirDrop the file to your iPhone or put it in iCloud Drive.

## Part B — on the iPhone

5. **Settings → Privacy & Security → Developer Mode → On**, then restart.
   (The switch appears once SideStore is installed.)
6. Install **LocalDevVPN** from the App Store, open it, tap **Connect**.
7. Open **SideStore → Sources → +**, add
   `https://raw.githubusercontent.com/rishi-sangare/elsewhere/main/source.json`, install **Elsewhere**.
8. Open **Elsewhere**:
   - allow **Location** (then **Always**) and **Notifications**
   - **Import pairing file** → pick the file from step 4
   - every row in the checklist should be green.

## Keeping it working

- Keep SideStore's background refresh on (free Apple IDs re-sign every 7 days).
- Keep LocalDevVPN connected while using Elsewhere, and Wi-Fi turned on.
- **After any iOS update**, make a new pairing file (Part A, step 4).

## Troubleshooting

| You see | Do this |
|---|---|
| "Couldn't reach this iPhone's developer service" | Connect LocalDevVPN; turn Wi-Fi on; if iOS was updated, new pairing file |
| "Couldn't mount Apple's developer files" | Check Developer Mode is on and you have internet (needed once per restart) |
| 🔴 "Real location may be visible" | Tap **Diagnose** — the checklist shows what's wrong |
| App won't open | SideStore certificate expired — open SideStore and refresh |
