---
agent: agent
description: Restart the kiosk display on ctrl-1
---

Restart the homelab kiosk display on ctrl-1 by running:

```bash
ssh pi@192.168.10.100 "sudo systemctl restart getty@tty1.service"
```

This restarts the tty1 session which triggers autologin → startx → kiosk.sh, relaunching Chromium with the Grafana playlist URL. Do not pkill chromium — the while loop in kiosk.sh would relaunch it with a stale URL.
