# kiosk.sh

Runs a fullscreen Chromium kiosk on `ctrl-1`'s attached 1U display, showing the Grafana playlist.

## What it does

1. Disables screensaver and display power management (`xset`)
2. Hides the mouse cursor after 1 second of inactivity (`unclutter`)
3. Waits for Grafana to be healthy before launching
4. Launches Chromium in kiosk mode pointing at the playlist
5. Restarts Chromium automatically if it crashes (`while true` loop)

## Display

GeeekPi 6.91" 1U rack-mount LCD, mounted in the DeskPi RackMate and driven from `ctrl-1` over micro-HDMI.

- Resolution: 1424×280 native
- URL: `https://grafana.local.lab/playlists/play/adc6g24?kiosk`
- Memory-constrained flags: `--max-old-space-size=64`, `--renderer-process-limit=1`

Confirm the touch state at any time:

```bash
# Lists only root hubs while the touch lead is unplugged
ssh pi@192.168.10.100 "lsusb && DISPLAY=:0 xinput list"
```

## Restart the kiosk display on ctrl-1

Restart the homelab kiosk display on ctrl-1 by running:

```bash
ssh pi@192.168.10.100 "sudo systemctl restart getty@tty1.service"
```

This restarts the tty1 session which triggers autologin → startx → kiosk.sh, relaunching Chromium with the Grafana playlist URL. Do not pkill chromium — the while loop in kiosk.sh would relaunch it with a stale URL.

Playlist URL: `https://grafana.local.lab/playlists/play/adc6g24?kiosk`

## How to update the URL without rebooting

```bash
ssh pi@192.168.10.100 "sed -i 's|OLD_URL|NEW_URL|' ~/kiosk.sh"
sudo systemctl restart getty@tty1.service
```

Restarting `getty@tty1` re-runs autologin → `.bashrc` → `kiosk.sh` with the new URL.
Do **not** just `pkill chromium` — the loop will relaunch with the old URL still in memory.

## X server requirement

Requires `/etc/X11/xorg.conf.d/99-pi5.conf` on `ctrl-1` to force the display DRM device.
See [Homelab Cluster Context → 1U Display](../../CLAUDE.md#1u-display-ctrl-1) for the config file contents.
