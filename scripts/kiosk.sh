#!/bin/bash
xset s off && xset -dpms && xset s noblank
unclutter -idle 1 -root &

until curl -sk https://grafana.local.lab/api/health | grep -q '"database": "ok"'; do
  sleep 10
done

while true; do
  chromium --noerrdialogs --disable-infobars --kiosk --incognito --disable-translate --disable-features=TranslateUI --ignore-certificate-errors --force-device-scale-factor=1 --window-size=1424,280 --disable-gpu --disable-dev-shm-usage "--js-flags=--max-old-space-size=64" --renderer-process-limit=1 --disable-extensions --disable-background-networking --disable-sync --disable-hang-monitor --disable-component-update --process-per-site "https://grafana.local.lab/playlists/play/admt9pc?kiosk"
  sleep 2
done
