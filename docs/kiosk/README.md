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

```bash
ssh pi@192.168.10.100 "sudo systemctl restart getty@tty1.service"
```

This restarts the tty1 session, which runs autologin → `startx` → `kiosk.sh` and relaunches Chromium with the URL in `kiosk.sh`. Do not `pkill chromium`. The `while true` loop in `kiosk.sh` relaunches it with the old URL still in memory.

## How to update the URL without rebooting

```bash
ssh pi@192.168.10.100 "sed -i 's|OLD_URL|NEW_URL|' ~/kiosk.sh"
```

Then restart the display with the command above.

## Check the display remotely

Take a screenshot (`scrot` is installed on `ctrl-1`):

```bash
ssh pi@192.168.10.100 "DISPLAY=:0 scrot /tmp/kiosk.png" && scp pi@192.168.10.100:/tmp/kiosk.png /tmp/kiosk.png && open /tmp/kiosk.png
```

Check the session and processes:

```bash
ssh pi@192.168.10.100 "journalctl -u getty@tty1 -n 30 --no-pager && ps aux | grep -E 'chromium|kiosk|Xorg' | grep -v grep"
```

## Set up a rebuilt ctrl-1

Copy the script from the repo root on your machine.

```bash
scp docs/kiosk/kiosk.sh pi@192.168.10.100:~/kiosk.sh
ssh pi@192.168.10.100 "chmod +x ~/kiosk.sh"
```

Then run the rest on `ctrl-1`. The Xorg file forces the HDMI DRM device and sets the real panel size, because the EDID reports 432x243mm and Chromium miscalculates the viewport.

```bash
sudo apt install -y --no-install-recommends xserver-xorg x11-xserver-utils xinit chromium unclutter
echo '192.168.10.100  grafana.local.lab' | sudo tee -a /etc/hosts
sudo sed -i '/^::1 localhost/a 192.168.10.100  grafana.local.lab' /etc/cloud/templates/hosts.debian.tmpl

sudo mkdir -p /etc/X11/xorg.conf.d
sudo tee /etc/X11/xorg.conf.d/99-pi5.conf > /dev/null << EOF
Section "Device"
    Identifier "Modesetting"
    Driver "modesetting"
    Option "kmsdev" "/dev/dri/card1"
EndSection

Section "Monitor"
    Identifier "HDMI-1"
    DisplaySize 172 34
EndSection
EOF

echo '~/kiosk.sh' > ~/.xinitrc
echo '[[ -z $DISPLAY && $(tty) == /dev/tty1 ]] && startx -- -nocursor' >> ~/.bash_profile

sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << 'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin pi --noclear %I $TERM
EOF
sudo systemctl daemon-reload && sudo systemctl restart getty@tty1
```
