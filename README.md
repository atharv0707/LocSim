# LocSim

Set your iPhone's GPS location from the LocSim app on the phone.
The app sends the place you pick to **LocSimServer** on your Mac, which applies it
with [pymobiledevice3](https://github.com/doronz88/pymobiledevice3). No Xcode needed once the app is installed.

```
iPhone (LocSim app)  --HTTP-->  Mac (LocSimServer)  --pymobiledevice3-->  iPhone GPS
```

## One-time setup (on the Mac)

1. Install pymobiledevice3 into LocSim's own Python environment:
   `python3 -m venv LocSimServer/.venv && LocSimServer/.venv/bin/python -m pip install -U pymobiledevice3`
2. Make sure the iPhone shows up in Xcode (cable or Wi-Fi). LocSimServer reaches it through
   macOS's own connection (`--native`), the same one Xcode uses.
3. Run the server once in Terminal so macOS can ask for any permissions (e.g. local network):
   `LocSimServer/.venv/bin/python LocSimServer/locsim_server.py` – then tap **Set location** in the app to check it works, and Ctrl+C.
4. Keep it running permanently (starts at login, restarts if it stops):
   `./LocSimServer/install_service.sh`  (remove with `--uninstall`; log in `~/Library/Logs/LocSimServer.log`)

## Install the app on the iPhone

Open `LocSim.xcodeproj` in Xcode, pick your Personal Team under Signing & Capabilities,
choose your iPhone and press Run once. After that, open LocSim from the home screen.
(With a free Apple ID the app must be re-installed from Xcode every 7 days.)

In the app tap ⚙️ and enter the address LocSimServer printed, e.g. `atharvs-air.local:8765`,
or the Mac's Tailscale address when you're away from home.

## Using it

Search for a place (or paste Google Maps coordinates / tap the map) → **Set location** turns
simulation on, **Stop** turns it off and returns to real GPS. The status line shows whether it's on.
If the phone drops off, LocSimServer keeps retrying every 15 s until it's back.

## Notes

- The **app → Mac** link works anywhere your phone can reach the Mac (home Wi-Fi or Tailscale).
- The **Mac → iPhone** link (pymobiledevice3) needs the phone on USB or the same local network
  as the Mac; it may not work over Tailscale alone.
- Anyone who can reach port 8765 on your Mac can change your phone's location, so only use it
  on your home network / Tailnet.
