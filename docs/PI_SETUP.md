# Building the homeOS display (Raspberry Pi 5 + 10.1" touchscreen)

This takes about 45 minutes, most of it waiting on downloads and the build.
You need the parts in [HARDWARE.md](HARDWARE.md) and a computer to flash the SD
card.

## 1. Flash Raspberry Pi OS

1. Install **Raspberry Pi Imager** on your computer: <https://www.raspberrypi.com/software/>.
2. Choose:
   - **Device:** Raspberry Pi 5
   - **OS:** *Raspberry Pi OS (other)* → **Raspberry Pi OS Lite (64-bit)**. Lite
     has no desktop; homeOS is the only thing on the screen. The desktop edition
     also works, because the installer switches it to boot to the console.
   - **Storage:** your microSD card
3. When asked to apply OS customisation, choose **Edit settings**:
   - Hostname: `homeos`
   - Username and password: your choice (for example `pi`)
   - Wi-Fi network and password, and your country
   - Locale: your time zone, keyboard `us`
   - **Services:** enable SSH (password authentication)
4. Write the card.

## 2. Assemble

1. If you have the Active Cooler, attach it first: peel the thermal pads and
   clip it into the two mounting holes, then plug its fan cable into the
   **FAN** connector.
2. Insert the microSD card.
3. **Video:** connect a micro-HDMI → HDMI cable from the Pi's **HDMI0** port
   (the one next to the USB-C power port) to the screen's HDMI input.
4. **Touch:** connect a USB cable from one of the Pi's USB ports to the
   screen's touch/USB-C port.
5. **Power:** power the screen with its own supply. Plug the 27 W supply into
   the Pi last.

To mount it, the screen's VESA holes fit a wall arm or stand, and the Pi can
sit on the back in a case.

## 3. Install homeOS

From your computer, connect to the Pi. The first boot takes a minute or two.

```bash
ssh pi@homeos.local
```

Then on the Pi:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git
git clone https://github.com/rmantilla13/homeOS.git
cd homeOS
git checkout claude/initial-scaffold   # until the PR is merged
./display/deploy/install-pi.sh
sudo reboot
```

If the repository is private, `git clone` asks for credentials. Use your GitHub
username and a [personal access token](https://github.com/settings/tokens)
(read access to this repo is enough) as the password.

The script does the following:
- installs Qt 6, fonts and the on-screen keyboard
- builds and installs the app to `/usr/local/bin/homeos-display`
- writes `/etc/homeos/display.env` (screen scale, keyboard, backend settings)
- starts the app on every boot as the `homeos-display` service

After the reboot, the screen shows homeOS with demo data. Tap the chores and
rewards to try it.

## 4. Everyday commands

| Task | Command |
|---|---|
| Watch logs | `journalctl -u homeos-display -f` |
| Restart the app | `sudo systemctl restart homeos-display` |
| Stop it (use the console) | `sudo systemctl stop homeos-display` |
| Change settings | `sudo nano /etc/homeos/display.env`, then restart |
| Update to the latest code | `cd ~/homeOS && git pull && ./display/deploy/install-pi.sh && sudo systemctl restart homeos-display` |

## 5. Connect it to your family (cloud)

Until the backend is set up, the display runs on demo data. Once a Supabase
project exists (see the main README), do the following:

1. Edit `/etc/homeos/display.env` and set `HOMEOS_SUPABASE_URL` and
   `HOMEOS_SUPABASE_ANON_KEY`.
2. Run `sudo systemctl restart homeos-display`. The screen shows a 6-digit
   code.
3. In the iOS app, go to **Family → Pair a display** and enter the code.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Black screen, logs say `Could not open DRM device` or `no screens available` | Check which card drives HDMI with `ls /sys/class/drm/` (look for `cardN-HDMI-A-1`). Put that card in `/etc/homeos/kms.json`, for example `{ "device": "/dev/dri/card0" }`, then restart. |
| Picture is on the wrong HDMI port | Use **HDMI0**, the port next to USB-C power. |
| Touch doesn't respond | Make sure the touch USB cable is connected (HDMI carries video only). Check that the panel appears with `lsusb`, then restart the app. |
| Everything is too big or too small | Change `QT_SCALE_FACTOR` in `display.env`: 1.5 for this 10.1" panel, 1.25 for slightly more room. |
| Lightning-bolt icon or "under-voltage" warnings | Use the official 27 W USB-C supply. |
| Keyboard layout is wrong | Set `LANG` in `display.env`, for example `en_US.UTF-8`. |
| Wrong time on screen | Run `sudo timedatectl set-timezone America/New_York` (or your zone). |

## Try it without a Pi

### Same screen, on your computer

On Linux (or anywhere Qt 6 is installed), run the app at the panel's exact
size:

```bash
cmake -S display -B build/display && cmake --build build/display -j
QT_SCALE_FACTOR=1 ./build/display/homeos-display --windowed   # 1280×800 window = the 10.1" layout
```

### Simulated Pi with Docker

This runs the real install script on Debian Trixie for arm64 (the base of
Raspberry Pi OS). On an Apple Silicon Mac it runs natively; elsewhere Docker
emulates it, which is slower. The screen is served over VNC.

```bash
docker build --platform linux/arm64 -f display/deploy/pi-sim/Dockerfile -t homeos-pi-sim .
docker run --rm -p 5900:5900 homeos-pi-sim
```

Connect a VNC viewer such as [RealVNC Viewer](https://www.realvnc.com/en/connect/download/viewer/)
or TigerVNC to `localhost:5900`. The mouse acts as touch.

This checks packages, the build, the install and the app's behavior. It can't
simulate the Pi's GPU, its HDMI output or the touch panel; those only show up
on the real device.

Full-system emulation of Raspberry Pi OS in QEMU is possible, but QEMU has no
Pi 5 machine and no Pi GPU. It's slow and tests less than the Docker route.
