# Kiosk

[kiosk.sh](./kiosk.sh) runs fullscreen Chromium on `ctrl-1`'s 1U display, showing the Grafana playlist.

| Part | What the script does |
|---|---|
| Screen | `xset` turns off the screensaver and display power saving |
| Cursor | `unclutter` hides it after 1 second idle |
| Start | Waits for Grafana to be healthy, then opens the playlist |
| Crash | A `while true` loop relaunches Chromium |
| Daily | `timeout 24h` restarts Chromium, so an "Aw, Snap!" page recovers |

## Display

GeeekPi 6.91" 1U rack-mount LCD in the DeskPi RackMate, driven from `ctrl-1` over micro-HDMI.

| Setting | Value |
|---|---|
| Resolution | 1424×280 native |
| URL | `https://grafana.local.lab/playlists/play/adc6g24?kiosk` |
| Memory flags | `--max-old-space-size=64`, `--renderer-process-limit=1` |

Check the touch state. It lists only root hubs while the touch lead is unplugged.

```bash
ssh pi@192.168.10.100 "lsusb && DISPLAY=:0 xinput list"
```

## Restart the kiosk display on ctrl-1

This restarts the tty1 session. Autologin then runs `startx`, then `kiosk.sh`, which loads the URL from the file.

```bash
ssh pi@192.168.10.100 "sudo systemctl restart getty@tty1.service"
```

Do not `pkill chromium`. The `while true` loop relaunches it with the old URL still in memory.

## How to update the URL without rebooting

Edit the script, then restart the display as above.

```bash
ssh pi@192.168.10.100 "sed -i 's|OLD_URL|NEW_URL|' ~/kiosk.sh"
```

## Check the display remotely

Take a screenshot with `scrot`, which is installed on `ctrl-1`.

```bash
ssh pi@192.168.10.100 "DISPLAY=:0 scrot /tmp/kiosk.png" && scp pi@192.168.10.100:/tmp/kiosk.png /tmp/kiosk.png && open /tmp/kiosk.png
```

Check the session and processes.

```bash
ssh pi@192.168.10.100 "journalctl -u getty@tty1 -n 30 --no-pager && ps aux | grep -E 'chromium|kiosk|Xorg' | grep -v grep"
```

## Set up a rebuilt ctrl-1

Copy the script from the repo root on your machine.

```bash
scp docs/kiosk/kiosk.sh pi@192.168.10.100:~/kiosk.sh
ssh pi@192.168.10.100 "chmod +x ~/kiosk.sh"
```

Run the rest on `ctrl-1`. The Xorg file forces the HDMI DRM device and sets the real panel size. The EDID reports 432x243mm, and Chromium gets the viewport wrong with it.

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
