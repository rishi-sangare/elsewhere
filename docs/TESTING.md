# Testing on a real iPhone

The Simulator proves the app, the engine and the safety logic. These tests prove
the real-iPhone connection (assumptions A1–A8 in ARCHITECTURE.md §11). Please
file results as a GitHub issue: iPhone model, iOS version, pass/fail per test,
and the log from **Setup & diagnostics** (coordinates are yours to redact).

| # | Test | Steps | Pass when |
|---|---|---|---|
| T1 | Setup from scratch | Follow SETUP.md on a fresh install | Checklist all green |
| T2 | Teleport | Teleport far away; open Google Maps and WhatsApp → Share location | Both show the chosen place; pill 🟢 |
| T3 | App killed | While spoofing, swipe Elsewhere away in the app switcher | "Elsewhere stopped" notification within ~10 s; Maps returns to real location (note how many seconds) |
| T4 | Route + traffic | Drive 3 km at 40 km/h, moderate traffic; watch Google Maps | Smooth movement, stops at lights, pill stays 🟢 |
| T5 | Locked for an hour | Start a long route, lock the phone 60 min | Live Activity updates; still 🟢 when unlocked |
| T6 | No Wi-Fi | Wi-Fi off, mobile data on, start spoofing | Works, or a clear error (record which) |
| T7 | VPN dropped | Mid-route, disconnect LocalDevVPN | 🔴 alarm within ~5 s; recovers when reconnected |
| T8 | Restart | Restart the phone mid-session, open Elsewhere | Recovery banner; Resume works (re-mounts developer image) |
| T9 | Stop | Press Stop (app and lock screen) | Maps shows real location; pill ⚪ |
