# Setting up a node

A freshly flashed node needs one cleanup before it joins the cluster. Raspberry Pi OS ships a camera stack that the headless nodes never use.

## Remove the camera packages

The camera packages block every OS update on the node. A new camera release needs new packages, and unattended-upgrades never installs new packages. So it holds back the whole batch, firmware and tzdata included.

```bash
ssh pi@<node-ip> 'sudo apt-get purge -y rpicam-apps-core rpicam-apps-lite librpicam-app1 libcamera-ipa "libcamera0.*"'
```

Check that nothing is held back afterwards.

```bash
ssh pi@<node-ip> 'apt list --upgradable'
```
