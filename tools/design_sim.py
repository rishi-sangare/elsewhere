"""
Design-validation simulations for Elsewhere.

This is NOT a model of iOS. It models *our design* under *our stated assumptions*
(see docs/ARCHITECTURE.md, "Assumption register") and checks that the design
keeps its safety promises when things go wrong.

  1. Session safety  - fault-injection over the session state machine, comparing
                       the full design against a naive design.
  2. Motion engine   - checks the 40 km/h + traffic model produces believable,
                       physically bounded movement.
  3. Jitter          - shows why GPS noise must be correlated, not random.

Run:  python3 tools/design_sim.py
"""

import math
import random

DT = 0.5  # simulation step, seconds

# Assumption A1/A2: iOS keeps the simulated fix only while the DVT session is
# alive AND it has been refreshed recently. RouteSim holds the last coordinate
# every ~4 s while paused so iOS does not fall back to real GPS.
REVERT_AFTER = 4.0


# ---------------------------------------------------------------------------
# 1. Session safety
# ---------------------------------------------------------------------------

class Device:
    """Ground truth: what iOS is actually reporting to every app."""

    def __init__(self):
        self.session_alive = False
        self.last_set = -1e9

    def spoofing(self, t):
        return self.session_alive and (t - self.last_set) <= REVERT_AFTER


class App:
    HEARTBEAT = 1.0          # re-send current fix every second
    VERIFY_WINDOW = 3.0      # green only if read-back matched within this window
    LOST_AFTER = 5.0         # mismatch this long => "Lost" + alert
    DEADMAN_LEAD = 10.0      # local notification scheduled this far ahead
    BACKOFF = [0.5, 1, 2, 4, 8]

    def __init__(self, full_design=True):
        self.full = full_design
        self.alive = True
        self.intent = False            # user wants spoofing on
        self.state = "idle"
        self.last_beat = -1e9
        self.last_match = -1e9
        self.deadman_at = None
        self.retry_at = None
        self.retries = 0
        self.alerted = False
        self.last_send_ok = False

    # what the status pill shows
    def green(self, t):
        if not self.alive or not self.intent:
            return False
        if self.full:
            return self.state == "active" and (t - self.last_match) <= self.VERIFY_WINDOW
        return self.last_send_ok  # naive: "the last call didn't error"

    def raise_alert(self):
        self.alerted = True

    def step(self, t, dev, vpn_up, readback_is_spoofed):
        if not self.alive:
            if self.deadman_at is not None and t >= self.deadman_at:
                self.raise_alert()          # notification fires even though we're dead
                self.deadman_at = None
            return
        if not self.intent:
            return

        # Read-back: our own CLLocationManager sees what every app sees.
        if readback_is_spoofed:
            self.last_match = t
            if self.state in ("reconnecting", "lost"):
                self.state, self.retries, self.alerted = "active", 0, False

        if self.state == "active":
            if t - self.last_beat >= self.HEARTBEAT or not self.full and t - self.last_beat >= 30:
                self.last_beat = t
                ok = dev.session_alive
                if ok:
                    dev.last_set = t
                self.last_send_ok = ok
                if self.full:
                    self.deadman_at = t + self.DEADMAN_LEAD
                    if not ok:
                        self.state, self.retry_at = "reconnecting", t + self.BACKOFF[0]

        # Exposure alarm runs in EVERY state while the user wants spoofing - not only
        # in "active". (The first version of this simulation found an 18 s silent gap
        # because the alarm was paused while reconnecting.)
        if self.full and t - self.last_match > self.LOST_AFTER and not self.alerted:
            self.raise_alert()
            if self.state == "active":
                self.state, self.retry_at = "lost", t

        if self.full and self.state in ("reconnecting", "lost") and t >= (self.retry_at or 0):
            if vpn_up:
                dev.session_alive = True       # tunnel + DVT re-established
                dev.last_set = t
                self.state = "active"
                self.last_beat = t
                self.retries = 0
            else:
                self.retries += 1
                if self.retries >= len(self.BACKOFF):
                    self.state = "lost"
                    self.raise_alert()
                    self.retry_at = t + self.BACKOFF[-1]
                else:
                    self.retry_at = t + self.BACKOFF[self.retries]
            if self.state == "reconnecting":
                self.deadman_at = t + self.DEADMAN_LEAD


def run_episode(rng, full_design, horizon=900.0):
    dev, app = Device(), App(full_design)
    vpn_up = True
    # user starts spoofing at t=5
    start_at = 5.0
    stop_at = rng.uniform(600, 850)
    killed_at = rng.uniform(100, 800) if rng.random() < 0.25 else None
    vpn_down = (rng.uniform(50, 700), rng.uniform(5, 120)) if rng.random() < 0.4 else None
    drop_rate = 1 / 180.0  # tunnel drops on average every 3 minutes (pessimistic)

    readback_lag = []  # CoreLocation read-back arrives ~1 s late
    stale_green = 0.0  # contiguous time green while NOT spoofing
    worst_stale_green = 0.0
    unspoofed_since = None
    worst_unalerted = 0.0
    green_after_stop = 0.0

    t = 0.0
    while t < horizon:
        if abs(t - start_at) < DT / 2:
            app.intent, app.state = True, "active"
            dev.session_alive, dev.last_set = True, t
            app.last_beat = app.last_match = t
        if abs(t - stop_at) < DT / 2 and app.alive:
            app.intent, app.state = False, "idle"
            dev.session_alive = False  # clear + close
            app.deadman_at = None
        if killed_at is not None and abs(t - killed_at) < DT / 2:
            app.alive = False
            dev.session_alive = False  # process death closes the socket
        if vpn_down:
            vpn_up = not (vpn_down[0] <= t < vpn_down[0] + vpn_down[1])
            if not vpn_up:
                dev.session_alive = False
        if dev.session_alive and rng.random() < drop_rate * DT:
            dev.session_alive = False

        readback_lag.append(dev.spoofing(t))
        rb = readback_lag[-3] if len(readback_lag) >= 3 else False
        app.step(t, dev, vpn_up, rb)

        spoofed = dev.spoofing(t)
        intent = app.intent or (not app.alive and killed_at is not None and t < stop_at)

        # I1: green must never be shown for long while the phone shows the REAL location
        if app.green(t) and not spoofed:
            stale_green += DT
            worst_stale_green = max(worst_stale_green, stale_green)
        else:
            stale_green = 0.0

        # I2: if the user wants spoofing but the phone is real, they must be told quickly
        if intent and not spoofed:
            if unspoofed_since is None:
                unspoofed_since = t
            if not app.alerted:
                worst_unalerted = max(worst_unalerted, t - unspoofed_since)
        else:
            unspoofed_since = None

        # I3: after Stop, nothing may still claim spoofing
        if t > stop_at + 1 and app.green(t):
            green_after_stop += DT
        t += DT

    return worst_stale_green, worst_unalerted, green_after_stop


def session_safety(n=5000):
    print("1. SESSION SAFETY  (%d randomized 15-minute sessions with injected faults)" % n)
    print("   faults: tunnel drops ~every 3 min, 40% VPN outages, 25% app killed by iOS\n")
    for label, full in (("naive design", False), ("Elsewhere design", True)):
        rng = random.Random(42)
        res = [run_episode(rng, full) for _ in range(n)]
        stale = max(r[0] for r in res)
        unalerted = [r[1] for r in res]
        after_stop = max(r[2] for r in res)
        silent = sum(1 for u in unalerted if u > 15)
        print(f"   {label}")
        print(f"     I1 worst 'green' while phone showed REAL location : {stale:6.1f} s")
        print(f"     I2 worst time real location exposed, user not told: {max(unalerted):6.1f} s")
        print(f"        sessions where user was not told for >15 s     : {silent} / {n}")
        print(f"     I3 worst 'green' after Stop                       : {after_stop:6.1f} s\n")


# ---------------------------------------------------------------------------
# 2. Motion engine
# ---------------------------------------------------------------------------

def make_route(rng, length_m=8000):
    """A synthetic city route: straight blocks joined by turns at intersections."""
    pts, heading, x, y, s = [(0.0, 0.0)], 0.0, 0.0, 0.0, 0.0
    intersections = []
    while s < length_m:
        block = rng.uniform(150, 450)
        for _ in range(int(block)):
            x += math.cos(heading)
            y += math.sin(heading)
            pts.append((x, y))
        s += block
        intersections.append(s)
        turn = rng.choice([0, 0, 0, math.pi / 2, -math.pi / 2, math.pi / 6, -math.pi / 6])
        # round the corner with a radius so curvature is finite
        radius = 12.0 if abs(turn) > 1 else 60.0
        steps = max(1, int(abs(turn) * radius))
        for _ in range(steps):
            heading += turn / steps
            x += math.cos(heading)
            y += math.sin(heading)
            pts.append((x, y))
        s += steps
    return pts, intersections


def curvature_speed_limits(pts, a_lat):
    lim = [float("inf")] * len(pts)
    for i in range(2, len(pts) - 2):
        (x0, y0), (x1, y1), (x2, y2) = pts[i - 2], pts[i], pts[i + 2]
        a = math.hypot(x1 - x0, y1 - y0)
        b = math.hypot(x2 - x1, y2 - y1)
        c = math.hypot(x2 - x0, y2 - y0)
        area2 = abs((x1 - x0) * (y2 - y0) - (y1 - y0) * (x2 - x0))
        if area2 > 1e-6:
            r = a * b * c / (2 * area2)
            lim[i] = math.sqrt(a_lat * r)
    return lim


def value_noise(rng, length, wavelength):
    knots = [rng.random() for _ in range(int(length / wavelength) + 3)]

    def f(s):
        k = s / wavelength
        i = int(k)
        u = k - i
        u = u * u * (3 - 2 * u)
        return knots[i] * (1 - u) + knots[i + 1] * u
    return f


TRAFFIC = {  # (congestion depth, stop probability at intersection, stop dwell range s)
    "none": (0.00, 0.00, (0, 0)),
    "light": (0.20, 0.15, (5, 20)),
    "moderate": (0.45, 0.35, (10, 45)),
    "heavy": (0.70, 0.55, (20, 75)),
}


def drive(rng, pts, intersections, cruise_kmh, traffic):
    cruise = cruise_kmh / 3.6
    a_acc, a_brk, a_lat = 2.0, 2.5, 2.0
    depth, p_stop, dwell = TRAFFIC[traffic]
    lim = curvature_speed_limits(pts, a_lat)
    total = len(pts) - 1
    congestion = value_noise(rng, total, 600)
    stops = {round(s): rng.uniform(*dwell) for s in intersections if rng.random() < p_stop}

    # Backward pass: curvature envelope, so we slow down *before* corners.
    env = [min(cruise, l) for l in lim]
    for i in range(len(env) - 2, -1, -1):
        env[i] = min(env[i], math.sqrt(env[i + 1] ** 2 + 2 * a_brk))

    # Stops (red lights, end of route) use the exact continuous braking curve
    # v <= sqrt(2 * a_brk * distance_to_stop), so we arrive at ~0 km/h, never snap.
    stop_queue = sorted(stops) + [total]
    s, v, t, dwell_left = 0.0, 0.0, 0.0, 0.0
    trace, max_v, max_a, prev_v, n_stops = [], 0.0, 0.0, 0.0, 0
    tick = 1.0
    sub = 20
    while s < total - 0.5:
        for _ in range(sub):
            h = tick / sub
            i = min(int(s), total)
            if dwell_left > 0:
                dwell_left -= h
                v = 0.0
                continue
            to_stop = stop_queue[0] - s
            if to_stop <= 0.5 and v <= 0.5 and len(stop_queue) > 1:
                dwell_left = stops[stop_queue.pop(0)]   # wait at the light, then go
                n_stops += 1
                v = 0.0
                continue
            target = min(env[i], cruise * (1 - depth * congestion(s)),
                         math.sqrt(2 * a_brk * max(to_stop, 0.0)) + 0.4)
            if v < target:
                v = min(target, v + a_acc * h)
            else:
                v = max(target, v - a_brk * h)
            s += v * h
        t += tick
        max_v = max(max_v, v)
        max_a = max(max_a, abs(v - prev_v) / tick)
        prev_v = v
        trace.append(v)
        if t > 6 * 3600:
            break
    return {
        "time_min": t / 60,
        "avg_kmh": total / t * 3.6,
        "max_kmh": max_v * 3.6,
        "max_accel": max_a,
        "stops": n_stops,
    }


def motion_engine():
    print("2. MOTION ENGINE  (8 km synthetic city route, user picks 40 km/h)\n")
    print("   traffic    time    avg speed   max speed   max |accel|   stops")
    for traffic in TRAFFIC:
        rng = random.Random(7)
        pts, inter = make_route(rng)
        r = drive(random.Random(11), pts, inter, 40, traffic)
        print(f"   {traffic:9s} {r['time_min']:5.1f} min  {r['avg_kmh']:5.1f} km/h  "
              f"{r['max_kmh']:5.1f} km/h   {r['max_accel']:4.2f} m/s²     {r['stops']}")
    print("   check: max speed never exceeds 40 km/h, accel stays ~2.5 m/s² (normal car braking)\n")


# ---------------------------------------------------------------------------
# 3. Jitter
# ---------------------------------------------------------------------------

def jitter():
    print("3. GPS JITTER  (car parked; what speed does iOS derive from 1 Hz fixes?)\n")
    rng = random.Random(3)
    n = 3600
    for label in ("white noise ±3 m", "correlated AR(1) ±3 m"):
        x = y = 0.0
        speeds = []
        px = py = 0.0
        for _ in range(n):
            if label.startswith("white"):
                x, y = rng.gauss(0, 3), rng.gauss(0, 3)
            else:
                rho = 0.95
                sd = 3 * math.sqrt(1 - rho ** 2)
                x, y = rho * x + rng.gauss(0, sd), rho * y + rng.gauss(0, sd)
            speeds.append(math.hypot(x - px, y - py) * 3.6)
            px, py = x, y
        speeds.sort()
        print(f"   {label:24s} median phantom speed {speeds[n // 2]:5.1f} km/h, "
              f"95th pct {speeds[int(n * .95)]:5.1f} km/h")
    print("   => random noise makes a parked phone look like it's driving; use AR(1) while moving, freeze when parked\n")


if __name__ == "__main__":
    session_safety()
    motion_engine()
    jitter()
