#!/usr/bin/env python3
"""
LocSimServer – sets your iPhone's GPS from the LocSim app, using pymobiledevice3.

The LocSim app (on the phone) sends the place you pick here; this server runs
`pymobiledevice3 developer dvt simulate-location set` to apply it, and
`... clear` when you tap Off.

The Mac can only reach the iPhone on the same Wi-Fi or by cable, and iOS drops the simulated
location within seconds of losing that link. While the iPhone is away, the place you picked
is kept and set again automatically when it's back.

One-time setup (Terminal):
    python3 -m pip install -U pymobiledevice3

Run it:
    python3 LocSimServer/locsim_server.py
Or keep it running all the time (starts at login, restarts if it crashes):
    ./LocSimServer/install_service.sh

Settings (environment variables):
    PORT      port to listen on (default 8765)
    PMD_ARGS  pymobiledevice3 connection options (default on macOS: "--native")
"""

import json
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8765"))
# On macOS, "--native" reaches the iPhone through Apple's own connection (the one Xcode uses),
# which works over cable and Wi-Fi without root. Override with PMD_ARGS if needed.
PMD_ARGS = os.environ.get("PMD_ARGS", "--native" if sys.platform == "darwin" else "").split()
RETRY_SECONDS = 15  # first retry after the iPhone drops off; doubles each time...
MAX_RETRY_SECONDS = 120  # ...up to this, so an iPhone away from home doesn't keep the Mac busy
CONFIRM_SECONDS = 20  # how long to wait for the iPhone to confirm a new location
# Remembers the location the iPhone is showing, so a restart of this server still knows it.
STATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".locsim_state.json")


def find_pymobiledevice3():
    # Prefer the module next to this Python (works even when pip's scripts folder isn't on PATH).
    try:
        import pymobiledevice3  # noqa: F401
        return [sys.executable, "-m", "pymobiledevice3"]
    except ImportError:
        found = shutil.which("pymobiledevice3")
        return [found] if found else None


PMD = find_pymobiledevice3()


def _short_error(output):
    """Turns pymobiledevice3's output into one readable line, e.g. "Device not found"."""
    lines = [l for l in output.splitlines() if l.strip()]
    if not lines:
        return ""
    last = lines[-1]
    if "ERROR" in last:
        last = last.split("ERROR", 1)[1].strip()
    if "Ctrl+C" in last:  # it had been holding the location and the link just dropped
        return ""
    if "Device not found" in last or "no device" in last.lower():
        return "the Mac can't see the iPhone (connect it by cable or the same Wi-Fi as this Mac)"
    return last


def log(text):
    print(f"{time.strftime('%H:%M:%S')}  {text}", flush=True)


class Simulator:
    """Owns the running `simulate-location set` process and the on/off state.

    Two things are tracked separately:
      target  – what you asked for in the app (a place, or None for Off)
      applied – what the iPhone was last confirmed to be showing

    iOS only keeps a simulated location while the Mac is linked to the iPhone: when the link
    drops (e.g. you leave home) the iPhone goes back to its real GPS within seconds. So while
    the iPhone is out of reach, the place you picked is kept as pending and set again
    automatically once the iPhone is back on the Mac's Wi-Fi (or plugged in).
    """

    def __init__(self):
        self.lock = threading.RLock()
        self.proc = None
        self.logfile = None
        self.applied = _load_state()   # (lat, lon, name) the iPhone is showing, or None
        self.target = self.applied     # (lat, lon, name) you want, or None when off
        self.connected = False         # True while pymobiledevice3 is linked to the iPhone
        self.last_error = None
        self.next_retry = time.time() + RETRY_SECONDS
        self.retry_delay = RETRY_SECONDS
        threading.Thread(target=self._watch, daemon=True).start()

    # -- public ---------------------------------------------------------------

    def set(self, lat, lon, name):
        with self.lock:
            self.target = (lat, lon, name)
            self._reset_retry()
            return self._apply()

    def clear(self):
        """Back to real GPS. Returns (ok, error); if the iPhone can't be reached it's retried later."""
        with self.lock:
            self.target = None
            self._reset_retry()
            was_linked = self.connected
            self._stop_process()
            self.connected = False
            if not was_linked:  # the iPhone already went back to real GPS when the link dropped
                self._set_applied(None)
                self.last_error = None
                return True, None
            return self._clear_on_phone()

    def status(self):
        # No lock: a retry in the background can take ~20 s and the app shouldn't hang on it.
        target, applied, connected, error = self.target, self.applied, self.connected, self.last_error
        away = "the iPhone isn't on the same Wi-Fi as the Mac (or plugged in)"
        if target is None and applied is None:
            return {"active": False, "linked": connected,
                    "message": "Off – the iPhone is using its real GPS."}
        if target is None:  # Off was tapped while a clear was still being confirmed
            return {"active": False, "linked": connected,
                    "message": "Off – the iPhone is using its real GPS."}
        t_lat, t_lon, t_name = target
        if connected and applied == target:
            return {"active": True, "linked": True, "name": t_name, "lat": t_lat, "lon": t_lon,
                    "message": f"On – the iPhone is at {t_name}."}
        # Not linked: iOS has dropped the simulated location, so the iPhone is on real GPS.
        return {"active": False, "linked": False, "pending": t_name, "name": t_name, "lat": t_lat, "lon": t_lon,
                "message": (f"The iPhone is on its real GPS – {t_name} will be set automatically when it's "
                            f"back on the Mac's Wi-Fi or plugged in ({error or away}).")}

    # -- internals ------------------------------------------------------------

    def _set_applied(self, value):
        self.applied = value
        _save_state(value)

    def _reset_retry(self):
        self.retry_delay = RETRY_SECONDS
        self.next_retry = time.time() + RETRY_SECONDS

    def _clear_on_phone(self):
        if self.applied is None:
            self.last_error = None
            return True, None
        if PMD is None:
            self.last_error = "pymobiledevice3 isn't installed on the Mac"
            return False, self.last_error
        try:
            result = subprocess.run(PMD + ["developer", "dvt", "simulate-location", "clear", *PMD_ARGS],
                                    capture_output=True, text=True, timeout=CONFIRM_SECONDS, check=False)
            ok = result.returncode == 0
            error = None if ok else (_short_error(result.stdout + result.stderr) or "pymobiledevice3 failed")
        except subprocess.TimeoutExpired:
            ok, error = False, "the iPhone didn't respond"
        if ok:
            self._set_applied(None)
            self.last_error = None
            return True, None
        self.last_error = error
        return False, error

    def _apply(self):
        """Starts pymobiledevice3 for self.target. Returns (ok, error)."""
        if PMD is None:
            self.last_error = "pymobiledevice3 isn't installed on the Mac (python3 -m pip install -U pymobiledevice3)"
            return False, self.last_error
        self._stop_process()
        lat, lon, _ = self.target
        self.logfile = tempfile.TemporaryFile()
        cmd = PMD + ["developer", "dvt", "simulate-location", "set", *PMD_ARGS, "--", repr(lat), repr(lon)]
        env = dict(os.environ, PYTHONUNBUFFERED="1")  # so we see its output straight away
        self.proc = subprocess.Popen(cmd, stdout=self.logfile, stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, start_new_session=True, env=env)
        # Only report success once pymobiledevice3 confirms it: when the location is applied it
        # prints "Press Ctrl+C ..." and keeps running to hold it. If it exits instead, it failed.
        deadline = time.time() + CONFIRM_SECONDS
        while time.time() < deadline:
            if "Ctrl+C" in self._peek_log():
                return self._applied_ok()
            code = self.proc.poll()
            if code is not None:
                output = self._read_log()
                self.proc = None
                if code == 0:  # older versions set the location and exit
                    return self._applied_ok()
                self.connected = False
                self.last_error = _short_error(output) or f"pymobiledevice3 exited with code {code}"
                return False, self.last_error
            time.sleep(0.25)
        # No confirmation in time – don't pretend it worked.
        self._stop_process()
        self.connected = False
        self.last_error = "the iPhone didn't respond"
        return False, self.last_error

    def _applied_ok(self):
        self.connected, self.last_error = True, None
        self._set_applied(self.target)
        self._reset_retry()
        return True, None

    def _peek_log(self):
        """Reads what pymobiledevice3 has printed so far without disturbing it."""
        if not self.logfile:
            return ""
        return os.pread(self.logfile.fileno(), 65536, 0).decode("utf-8", "replace")

    def _read_log(self):
        if not self.logfile:
            return ""
        self.logfile.seek(0)
        text = self.logfile.read().decode("utf-8", "replace").strip()
        self.logfile.close()
        self.logfile = None
        return text[-800:]

    def _stop_process(self):
        # Stopping pymobiledevice3 doesn't clear the location on the iPhone – only `clear` does.
        if self.proc and self.proc.poll() is None:
            self.proc.send_signal(signal.SIGINT)  # like Ctrl+C, so it can tidy up
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        self.proc = None
        if self.logfile:
            self.logfile.close()
            self.logfile = None

    def _watch(self):
        """Notices when the iPhone drops off, and finishes pending changes once it's back.

        Losing the iPhone doesn't turn simulation off: it keeps the last location. Retries back
        off from 15 s to 2 min so a phone that's away from home doesn't keep the Mac busy.
        """
        while True:
            time.sleep(1)
            with self.lock:
                if self.proc is not None and self.proc.poll() is not None:
                    output = self._read_log()  # it was linked to the iPhone and has now stopped
                    self.proc = None
                    self.connected = False
                    self.last_error = _short_error(output) or "connection to the iPhone was lost"
                    if self.target is not None:
                        log(f"Lost the iPhone ({self.last_error}) – it's back on real GPS; "
                            f"{self.target[2]} will be set again when it's back")
                if time.time() < self.next_retry:
                    continue
                self.next_retry = time.time() + self.retry_delay
                self.retry_delay = min(self.retry_delay * 2, MAX_RETRY_SECONDS)
                if self.target is None and self.applied is not None:
                    ok, _ = self._clear_on_phone()
                    if ok:
                        log("OFF  back to real GPS (iPhone is back)")
                elif self.target is not None and not self.connected:
                    was_pending = self.target != self.applied
                    ok, _ = self._apply()
                    if ok and was_pending:
                        log(f"ON   {self.target[2]}  (iPhone is back)")
                    elif ok:
                        log(f"Reconnected to the iPhone – still at {self.target[2]}")


def _load_state():
    try:
        with open(STATE_FILE) as f:
            data = json.load(f)
        return (float(data["lat"]), float(data["lon"]), str(data["name"]))
    except (OSError, ValueError, KeyError, TypeError):
        return None


def _save_state(applied):
    try:
        if applied is None:
            if os.path.exists(STATE_FILE):
                os.remove(STATE_FILE)
        else:
            lat, lon, name = applied
            with open(STATE_FILE, "w") as f:
                json.dump({"lat": lat, "lon": lon, "name": name}, f)
    except OSError:
        pass


sim = Simulator()


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the app gave up waiting; it will pick up the result from /status

    def do_GET(self):
        if self.path in ("/", "/status"):
            return self._reply(200, sim.status())
        self._reply(404, {"message": "Not found"})

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
            data = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self._reply(400, {"message": "Bad JSON"})

        if self.path == "/set":
            try:
                lat, lon = float(data["lat"]), float(data["lon"])
                if not (-90 <= lat <= 90 and -180 <= lon <= 180):
                    raise ValueError
            except (KeyError, TypeError, ValueError):
                return self._reply(400, {"message": "lat/lon missing or out of range"})
            name = str(data.get("name") or "Simulated location")[:100]
            ok, error = sim.set(lat, lon, name)
            if ok:
                log(f"ON   {name}  {lat:.6f}, {lon:.6f}")
                return self._reply(200, {"message": f"On – the iPhone is at {name}."})
            log(f"WAIT {name}: {error}")
            return self._reply(503, {"message": (
                f"Can't reach the iPhone – {error}. {name} will be set automatically once the iPhone "
                "is back on the Mac's Wi-Fi or plugged in.")})

        if self.path == "/clear":
            ok, error = sim.clear()
            if ok:
                log("OFF  back to real GPS")
                return self._reply(200, {"message": "Off – the iPhone is using its real GPS."})
            log(f"WAIT off: {error}")
            return self._reply(503, {"message": (
                f"Couldn't confirm Off with the iPhone – {error}. LocSimServer will keep trying.")})

        self._reply(404, {"message": "Not found"})

    def log_message(self, *args):
        pass  # keep the output readable


def addresses():
    host = socket.gethostname()
    found = [host if host.endswith(".local") else host + ".local"]
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("10.255.255.255", 1))  # no packet is sent; just picks the LAN interface
            found.append(s.getsockname()[0])
    except OSError:
        pass
    tailscale = shutil.which("tailscale") or "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    try:
        ip = subprocess.run([tailscale, "ip", "-4"], capture_output=True, text=True, timeout=5).stdout.strip()
        if ip:
            found.append(ip.splitlines()[0] + "  (Tailscale)")
    except (OSError, subprocess.SubprocessError):
        pass
    return found


def main():
    # Closing the Terminal or stopping the service: clear the location like Ctrl+C would.
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    log("LocSimServer running. In the LocSim app (Settings), use one of:")
    for address in addresses():
        print(f"     {address.split()[0]}:{PORT}{'  ' + ' '.join(address.split()[1:]) if ' ' in address else ''}")
    if PMD is None:
        print("\nWARNING: pymobiledevice3 not found. Install it with:\n     python3 -m pip install -U pymobiledevice3\n")
    print("Press Ctrl+C to stop.\n", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        log("Stopping – clearing the simulated location…")
        ok, error = sim.clear()
        if not ok:
            log(f"Couldn't confirm Off with the iPhone ({error}).")
        server.server_close()


if __name__ == "__main__":
    main()
