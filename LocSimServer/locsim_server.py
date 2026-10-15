#!/usr/bin/env python3
"""
LocSimServer – sets your iPhone's GPS from the LocSim app, using pymobiledevice3.

The LocSim app (on the phone) sends the place you pick here; this server runs
`pymobiledevice3 developer dvt simulate-location set` to apply it, and
`... clear` when you tap Stop.

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
RETRY_SECONDS = 15  # how often to retry if the phone drops off while simulation is on
CONFIRM_SECONDS = 20  # how long to wait for the iPhone to confirm a new location


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
    if "Device not found" in last or "no device" in last.lower():
        return "the Mac can't see the iPhone (connect it by cable or the same Wi-Fi as this Mac)"
    return last


def log(text):
    print(f"{time.strftime('%H:%M:%S')}  {text}", flush=True)


class Simulator:
    """Owns the running `simulate-location set` process and the on/off state."""

    def __init__(self):
        self.lock = threading.RLock()
        self.proc = None
        self.logfile = None
        self.target = None          # (lat, lon, name) the user wants, or None when off
        self.connected = False      # True while the location is actually applied
        self.last_error = None
        threading.Thread(target=self._watch, daemon=True).start()

    # -- public ---------------------------------------------------------------

    def set(self, lat, lon, name):
        with self.lock:
            self.target = (lat, lon, name)
            return self._apply()

    def clear(self):
        with self.lock:
            self.target = None
            self._stop_process()
            self.connected = False
            self.last_error = None
            if PMD:
                subprocess.run(PMD + ["developer", "dvt", "simulate-location", "clear", *PMD_ARGS],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               timeout=30, check=False)

    def status(self):
        with self.lock:
            if self.target is None:
                return {"active": False, "message": "Off – the iPhone is using its real GPS."}
            lat, lon, name = self.target
            if self.connected:
                message = f"On – the iPhone is at {name}."
            else:
                message = (f"Trying to reach the iPhone to set {name}… "
                           f"({self.last_error or 'not connected'})")
            return {"active": self.connected, "message": message, "name": name, "lat": lat, "lon": lon}

    # -- internals ------------------------------------------------------------

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
                self.connected, self.last_error = True, None
                return True, None
            code = self.proc.poll()
            if code is not None:
                output = self._read_log()
                self.proc = None
                if code == 0:  # older versions set the location and exit
                    self.connected, self.last_error = True, None
                    return True, None
                self.connected = False
                self.last_error = _short_error(output) or f"pymobiledevice3 exited with code {code}"
                return False, f"Couldn't reach the iPhone: {self.last_error}"
            time.sleep(0.25)
        # No confirmation in time – don't pretend it worked.
        self._stop_process()
        self.connected = False
        self.last_error = "the iPhone didn't respond"
        return False, ("Couldn't reach the iPhone: it didn't respond. Connect it to this Mac by cable "
                       "or put both on the same Wi-Fi.")

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
        """If the phone disconnects while simulation is on, keep retrying until it's back."""
        while True:
            time.sleep(RETRY_SECONDS)
            with self.lock:
                if self.target is None:
                    continue
                if self.proc is not None and self.proc.poll() is not None:
                    output = self._read_log()  # it was holding the location and has now died
                    self.proc = None
                    self.connected = False
                    self.last_error = _short_error(output) or "connection to the iPhone was lost"
                    log(f"Lost the iPhone: {self.last_error}")
                if not self.connected:
                    ok, _ = self._apply()
                    if ok:
                        log(f"Reconnected – location set to {self.target[2]} again")


sim = Simulator()


class Handler(BaseHTTPRequestHandler):
    def _reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
            log(f"FAIL {name}: {error}")
            return self._reply(500, {"message": error + " LocSimServer will keep retrying."})

        if self.path == "/clear":
            sim.clear()
            log("OFF  back to real GPS")
            return self._reply(200, {"message": "Off – the iPhone is using its real GPS."})

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
        sim.clear()
        server.server_close()


if __name__ == "__main__":
    main()
