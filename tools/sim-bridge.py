#!/usr/bin/env python3
"""
Simulator bridge: lets Elsewhere running in the iOS Simulator control the
Simulator's system-wide location, standing in for a real iPhone.

    python3 tools/sim-bridge.py            # uses the booted simulator
    python3 tools/sim-bridge.py --udid X   # a specific simulator
    python3 tools/sim-bridge.py --real 18.5204,73.8567   # pretend you're in Pune

The app calls http://127.0.0.1:47800 and this script runs
`xcrun simctl location <device> set|clear`.

To behave like a real iPhone (assumption A1 in docs/ARCHITECTURE.md), the
simulated fix is dropped if it isn't refreshed for --revert-after seconds, and
on exit. Stop this script mid-drive to rehearse "connection lost".
"""

import argparse
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = 47800


class Bridge:
    def __init__(self, device, revert_after, real=None):
        self.device = device
        self.real = real
        self.revert_after = revert_after
        self.lock = threading.Lock()
        self.last_set = None
        self.active = False
        self.sets = 0

    def simctl(self, *args):
        r = subprocess.run(["xcrun", "simctl", "location", self.device, *args],
                           capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            raise RuntimeError(r.stderr.strip() or "simctl failed")

    def set(self, lat, lon):
        with self.lock:
            self.simctl("set", f"{lat:.7f},{lon:.7f}")
            self.last_set = time.monotonic()
            self.active = True
            self.sets += 1

    def clear(self):
        with self.lock:
            if self.active:
                if self.real:
                    self.simctl("set", self.real)   # back to the pretend real location
                else:
                    self.simctl("clear")
            self.active = False

    def watchdog(self):
        while True:
            time.sleep(0.5)
            if self.revert_after <= 0:
                continue
            with self.lock:
                stale = self.active and time.monotonic() - self.last_set > self.revert_after
            if stale:
                log(f"no refresh for {self.revert_after:g}s → reverting to real location (like iOS)")
                try:
                    self.clear()
                except Exception as e:  # noqa: BLE001
                    log(f"clear failed: {e}")


def log(msg):
    print(time.strftime("%H:%M:%S"), msg, flush=True)


def make_handler(bridge):
    class Handler(BaseHTTPRequestHandler):
        def reply(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if urlparse(self.path).path == "/health":
                self.reply(200, {"ok": True, "device": bridge.device, "active": bridge.active})
            else:
                self.reply(404, {"error": "not found"})

        def do_POST(self):
            url = urlparse(self.path)
            try:
                if url.path == "/set":
                    q = parse_qs(url.query)
                    lat, lon = float(q["lat"][0]), float(q["lon"][0])
                    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                        return self.reply(400, {"error": "coordinate out of range"})
                    bridge.set(lat, lon)
                    if bridge.sets % 10 == 1:
                        log(f"set {lat:.5f},{lon:.5f}  (#{bridge.sets})")
                    return self.reply(200, {"ok": True})
                if url.path == "/clear":
                    bridge.clear()
                    log("cleared → real location")
                    return self.reply(200, {"ok": True})
                return self.reply(404, {"error": "not found"})
            except (KeyError, ValueError):
                return self.reply(400, {"error": "need lat & lon"})
            except Exception as e:  # noqa: BLE001
                log(f"error: {e}")
                return self.reply(500, {"error": str(e)})

        def log_message(self, *_):
            pass

    return Handler


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--udid", default="booted", help="simulator UDID (default: booted)")
    ap.add_argument("--revert-after", type=float, default=4.0,
                    help="seconds without a refresh before reverting, like iOS (0 = never)")
    ap.add_argument("--real", metavar="LAT,LON",
                    help="the simulator's pretend real location, restored on stop/revert (e.g. 18.5204,73.8567)")
    args = ap.parse_args()

    bridge = Bridge(args.udid, args.revert_after, args.real)
    if args.real:
        bridge.simctl("set", args.real)
    threading.Thread(target=bridge.watchdog, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), make_handler(bridge))
    log(f"Elsewhere simulator bridge on http://127.0.0.1:{PORT} → device '{args.udid}'")
    log("Ctrl+C to stop (the simulator returns to its real location)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            bridge.clear()
        except Exception:  # noqa: BLE001
            pass
        log("bridge stopped")
        sys.exit(0)


if __name__ == "__main__":
    main()
