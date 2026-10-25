#!/bin/bash
# Keeps LocSimServer running in the background on this Mac:
# starts when you log in and restarts automatically if it stops.
#
#   ./install_service.sh              install / reinstall
#   ./install_service.sh --uninstall  remove it
#
# Logs: ~/Library/Logs/LocSimServer.log
set -euo pipefail

LABEL="com.atharvtiwari.locsim"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/LocSimServer.log"
DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER="$DIR/locsim_server.py"
# Prefer LocSim's own Python environment (LocSimServer/.venv) if it exists.
if [[ -x "$DIR/.venv/bin/python" ]]; then DEFAULT_PYTHON="$DIR/.venv/bin/python"; else DEFAULT_PYTHON="$(command -v python3)"; fi
PYTHON="${PYTHON:-$DEFAULT_PYTHON}"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# bootout returns before the old server has finished shutting down (it clears the location on
# the way out, which can take ~20 s). Bootstrapping before it's gone fails with
# "Bootstrap failed: 5: Input/output error", so wait for it.
for _ in $(seq 1 40); do
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
    sleep 1
done

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -f "$PLIST"
    echo "LocSimServer removed. It will no longer start automatically."
    exit 0
fi

if ! "$PYTHON" -c "import pymobiledevice3" 2>/dev/null; then
    echo "pymobiledevice3 isn't installed for $PYTHON. Install it first:"
    echo "    $PYTHON -m pip install -U pymobiledevice3"
    exit 1
fi

mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$PYTHON</string>
        <string>-u</string>
        <string>$SERVER</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
echo "LocSimServer is now running in the background and will start every time you log in."
echo "Addresses to put in the LocSim app (Settings):"
grep -A4 "use one of" "$LOG" 2>/dev/null | tail -n +2 | grep ':' | tail -4 || true
echo "Log: $LOG"
