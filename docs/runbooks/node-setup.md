# Setting up a node

A freshly flashed node needs one cleanup before it joins the cluster.

## Remove the camera packages

Raspberry Pi OS ships a camera stack the headless nodes never use. It blocks every OS update. Unattended-upgrades never installs new packages, so a camera release holds back the whole batch, firmware and tzdata included.

```bash
ssh pi@<node-ip> 'sudo apt-get purge -y rpicam-apps-core rpicam-apps-lite librpicam-app1 libcamera-ipa "libcamera0.*"'
```

Check that nothing is held back afterwards.

```bash
ssh pi@<node-ip> 'apt list --upgradable'
```
