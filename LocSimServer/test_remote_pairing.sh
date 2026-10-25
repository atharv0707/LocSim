#!/bin/bash
# Tests whether the iPhone's RemotePairing service (the iOS 17+ developer link) can be
# reached over Tailscale when the iPhone is on mobile data.
# Run with the iPhone unlocked and on the same Wi-Fi as this Mac:
#     bash LocSimServer/test_remote_pairing.sh

PHONE_TS_IP="100.121.241.107"
TAILSCALE="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
tmp=$(mktemp -d)

run_for() {  # run_for SECONDS OUTFILE cmd... : run a command for a few seconds, capturing output
  local secs=$1 out=$2; shift 2
  "$@" </dev/null >"$out" 2>&1 &   # dns-sd line-buffers its output, so a file is fine
  local pid=$!
  sleep "$secs"; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

echo "== Step 1: looking for the iPhone's RemotePairing service on Wi-Fi (6 s)…"
run_for 6 "$tmp/browse" dns-sd -B _remotepairing._tcp
names=$(tr -d '\r' < "$tmp/browse" | awk '$2=="Add" { $1=$2=$3=$4=$5=$6=""; sub(/^ +/, ""); print }' | sort -u)
if [ -z "$names" ]; then
  echo "   Nothing found. Is the iPhone unlocked and on this Wi-Fi?"
  echo "   Trying the manual-pairing service instead…"
  service=_remotepairing-manual-pairing._tcp
  run_for 6 "$tmp/browse" dns-sd -B $service
  names=$(tr -d '\r' < "$tmp/browse" | awk '$2=="Add" { $1=$2=$3=$4=$5=$6=""; sub(/^ +/, ""); print }' | sort -u)
else
  service=_remotepairing._tcp
fi
[ -z "$names" ] && { echo "   Still nothing found – stopping."; exit 1; }

ports=""
while IFS= read -r name; do
  run_for 4 "$tmp/resolve" dns-sd -L "$name" "$service"
  hostport=$(tr -d '\r' < "$tmp/resolve" | grep -o 'reached at [^ ]*' | head -1 | awk '{print $3}')
  host=${hostport%:*}; port=${hostport##*:}
  echo "   Found: \"$name\"  ->  ${host}  port ${port}"
  [ -n "$port" ] && ports="$ports $host:$port"
done <<< "$names"
[ -z "$ports" ] && { echo "   Couldn't read a port – stopping."; exit 1; }

echo
echo "== Step 2: checking the port(s) work over Wi-Fi…"
for hp in $ports; do nc -vz -w 5 "${hp%:*}" "${hp##*:}" 2>&1 | sed 's/^/   /'; done

echo
echo "=================================================================="
echo "  NOW: turn OFF Wi-Fi on the iPhone (Control Centre or Settings)."
echo "  Make sure the Tailscale app on the iPhone still says Connected."
echo "  Then press Enter here."
echo "=================================================================="
read -r
echo "   Waiting 10 s for the iPhone to switch to mobile data…"; sleep 10

echo
echo "== Step 3: the real test – over Tailscale (${PHONE_TS_IP})…"
"$TAILSCALE" ping -c 3 "$PHONE_TS_IP" 2>&1 | tail -1 | sed 's/^/   tailscale ping: /'
ok=0
for hp in $ports; do
  port=${hp##*:}
  result=$(nc -vz -w 5 "$PHONE_TS_IP" "$port" 2>&1)
  echo "   port $port: $result"
  echo "$result" | grep -q succeeded && ok=1
done

echo
if [ $ok = 1 ]; then
  echo "RESULT: OPEN – the iPhone accepts RemotePairing over Tailscale. Worth building on."
else
  echo "RESULT: BLOCKED – the iPhone doesn't accept RemotePairing over Tailscale."
fi
echo "(You can turn the iPhone's Wi-Fi back on now.)"
rm -rf "$tmp"
