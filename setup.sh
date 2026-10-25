#!/bin/bash
# First-time setup for LocSimServer on a Mac.
#
#   ./setup.sh                 set up the Python environment and install the background service
#   ./setup.sh --no-service    set up the Python environment only (run the server yourself)
#
# Safe to run again: it reuses the existing environment and updates pymobiledevice3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$ROOT/LocSimServer"
VENV="$SERVER_DIR/.venv"
INSTALL_SERVICE=1
[[ "${1:-}" == "--no-service" ]] && INSTALL_SERVICE=0

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '\nERROR: %s\n' "$1" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "LocSimServer needs macOS (it reaches the iPhone through macOS's own device connection)."

step "Checking for Python 3"
PYTHON3="$(command -v python3 || true)"
[[ -n "$PYTHON3" ]] || fail "python3 not found. Install it with Homebrew (brew install python) or from python.org, then run this again."
"$PYTHON3" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
    || fail "Python 3.9 or newer is needed ($("$PYTHON3" --version) found)."
echo "    Using $("$PYTHON3" --version) at $PYTHON3"

step "Creating the project's Python environment (LocSimServer/.venv)"
if [[ -x "$VENV/bin/python" ]]; then
    echo "    Already exists – reusing it."
else
    "$PYTHON3" -m venv "$VENV"
fi

step "Installing / updating pymobiledevice3 (this can take a minute)"
"$VENV/bin/python" -m pip install --quiet --upgrade pip
"$VENV/bin/python" -m pip install --quiet --upgrade pymobiledevice3
echo "    pymobiledevice3 $("$VENV/bin/python" -c 'from importlib.metadata import version; print(version("pymobiledevice3"))')"

chmod +x "$SERVER_DIR/install_service.sh" "$SERVER_DIR/locsim_server.py" 2>/dev/null || true

if [[ $INSTALL_SERVICE == 1 ]]; then
    step "Installing the background service (starts at login, restarts if it stops)"
    bash "$SERVER_DIR/install_service.sh"
else
    step "Skipping the background service. Start the server yourself with:"
    echo "    $VENV/bin/python $SERVER_DIR/locsim_server.py"
fi

cat <<NEXT

Done. Next steps (see README.md › Setup for details):
  1. iPhone: plug it into this Mac, tap Trust, and turn on
     Settings › Privacy & Security › Developer Mode.
  2. Build the LocSim app onto the iPhone from Xcode (LocSim.xcodeproj).
  3. In the app's Settings, enter:  $(scutil --get LocalHostName 2>/dev/null || hostname -s).local:8765
NEXT
