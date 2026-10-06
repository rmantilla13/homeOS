# Setting up the homeOS display (Raspberry Pi 5 + 10.1" touchscreen)

This takes about an hour, most of it waiting for downloads and the build.

You need:
- the Raspberry Pi 5 (8 GB) with its Active Cooler and the official 27 W USB-C
  power supply
- the JUNEBOX 10.1" screen, its power adapter, a micro-HDMI → HDMI cable and a
  USB cable for touch
- a microSD card (64 GB or more, A2) and a computer with a card reader
- optional: a USB microphone, for voice

More about the parts: [HARDWARE.md](HARDWARE.md).

## 1. Flash the microSD card

1. On your computer, install and open **Raspberry Pi Imager**
   (<https://www.raspberrypi.com/software/>).
2. **Device:** Raspberry Pi 5, then **Next**.
3. **OS:** *Raspberry Pi OS (other)* → **Raspberry Pi OS Lite (64-bit)**, then
   **Next**. Lite has no desktop, so homeOS is the only thing on the screen.
4. **Storage:** your microSD card, then **Next**.
5. **Customisation:**
   - **Hostname:** `homeos`
   - **Localisation:** your capital city (this sets the time zone, the
     keyboard and the Wi-Fi country)
   - **User:** a username and password, for example `pi`. You'll need them
     to log in.
   - **Wi-Fi:** your network name and password
   - **Remote Access:** turn on **Enable SSH** and choose **Use password
     authentication**
   - **Raspberry Pi Connect:** not needed; skip it
6. **Write**, then **I understand, erase and write**. When Imager says it's
   done, take out the card.

## 2. Put it together

1. **Cooler:** take the film off the Active Cooler's thermal pads, push its two
   pins through the holes on the Pi until they click, and plug its cable into
   the **FAN** connector (next to the USB ports). The fan spins briefly at
   power-on, then only when the Pi gets warm.
2. **SD card:** push it into the slot under the board, contacts facing the
   board.
3. **Video:** connect the micro-HDMI cable to the Pi's **HDMI0** port, the one
   next to the USB-C power port, and to the screen's HDMI input.
4. **Touch:** connect the USB cable from any of the Pi's USB ports to the
   screen's touch (USB) port. HDMI carries only the picture and sound.
5. **Screen power:** plug in the screen's own power adapter and turn the
   screen on. Don't run the screen from the Pi's USB ports: they share 1.6 A
   between all USB devices.
6. **Pi power:** plug in the 27 W supply last. The Pi starts by itself.

Turn the screen on before the Pi when you can. If it comes on later, homeOS
appears a few seconds after it does, but its sound may not work until the Pi
restarts (see [Troubleshooting](#troubleshooting)).

Mount the screen in landscape. Portrait or upside-down mounting isn't
supported yet.

## 3. Install homeOS

The first boot takes a few minutes, and the Pi may restart once by itself.
Then, from a terminal on your computer (Terminal on a Mac, PowerShell on
Windows), log in with the username you chose:

```bash
ssh pi@homeos.local
```

On the Pi:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y git
git clone https://github.com/rmantilla13/homeOS.git
cd homeOS
./display/deploy/install-pi.sh
sudo reboot
```

If the repository is private, `git clone` asks for a username and password.
Use your GitHub username and a
[personal access token](https://github.com/settings/tokens) (read access to
this repo is enough) as the password.

Keep your computer awake until it's done: if it sleeps or the connection
drops, the command stops part-way. Then log in again, run
`sudo dpkg --configure -a` (it finishes a half-done package install), and run
the command that was cut off again. Everything here is safe to re-run.

The script takes 20–30 minutes. It:
- installs Qt 6, PipeWire (for sound) and fonts, then builds and installs the
  app to `/usr/local/bin/homeos-display`
- finds the HDMI output (`/etc/homeos/kms.json`) and writes the settings file
  `/etc/homeos/display.env` (kept when you re-run it)
- stops the text console from blanking the screen or showing a cursor behind
  the app (in `/boot/firmware/cmdline.txt`; the original is saved as
  `cmdline.txt.homeos-backup`)
- sends sound to the screen's speakers at half volume (full volume on this
  panel is mostly hiss; the gear menu turns the speakers off or up, and the
  screen's own buttons still work), and turns off Wi-Fi power saving, which
  makes Wi-Fi drop out
- starts the app on every boot as the `homeos-display` service
- warns at the end if the Pi has been short of power

## 4. What you should see

After the reboot, boot messages scroll by for about half a minute, then
homeOS fills the screen with sample data. Tap the chores and rewards to try
it. Videos under **Media** play with sound from the screen's speakers. After
two minutes without a touch, the photo frame starts; a tap wakes it.

## 5. Connect it to your family

Until the backend is set up, the display shows sample data. Once there's a
Supabase project (see the main README):

1. Run `sudo nano /etc/homeos/display.env` and set `HOMEOS_SUPABASE_URL` and
   `HOMEOS_SUPABASE_ANON_KEY` (remove the `#` in front of each).
2. Run `sudo systemctl restart homeos-display`. The screen shows a 6-digit
   code.
3. In the iOS app, go to **Family → Pair a display** and enter the code.

## 6. Voice (optional)

The screen has speakers but no microphone, so voice needs a USB microphone.
Plug it into one of the Pi's USB ports, then:

```bash
cd ~/homeOS
./voice/deploy/install-voice.sh
```

This downloads about 220 MB of speech models. Then say "Hey Jarvis" and ask a
question. You can also install voice together with the display:
`./display/deploy/install-pi.sh --with-voice` (add `--skip-models` to fetch the
models later). Details and voice troubleshooting: [VOICE.md](VOICE.md).

## Everyday commands

| Task | Command |
|---|---|
| Watch the logs | `journalctl -u homeos-display -f` |
| Restart the app | `sudo systemctl restart homeos-display` |
| Change Wi-Fi, volume, restart or reboot | On the screen, tap the gear. Wi-Fi and reboot need the helper from the install script |
| Change app settings | `sudo nano /etc/homeos/display.env`, then restart the app |
| Update to the latest code | `cd ~/homeOS && git pull && ./display/deploy/install-pi.sh` (updates the voice service too, if installed) |
| Get a login prompt on the screen | `sudo systemctl stop homeos-display && sudo systemctl start getty@tty1` |
| Check power and temperature | `vcgencmd get_throttled` (`0x0` is good) and `vcgencmd measure_temp` |

## Troubleshooting

Start with the logs: `journalctl -u homeos-display -b`.

| Symptom | Fix |
|---|---|
| Boot messages stay on the screen, and the log repeats `No modes available`, `Could not open DRM device` or a crash | The app can't find the screen and retries every 3 seconds. Check that the cable is in **HDMI0** and the screen is on and set to HDMI. `cat /etc/homeos/kms.json` should name a device from `ls -l /dev/dri/by-path/`; re-run `./display/deploy/install-pi.sh` to detect it again. |
| The gear menu says it isn't allowed to change Wi-Fi | Re-run `./display/deploy/install-pi.sh`. It installs `/usr/local/libexec/homeos-system` and lets your user run that, and only that, without a password. |
| `Permission denied` for `/dev/dri` or `/dev/input` in the log | Run `groups`: it should list `video render input audio`. Re-run the install script, then `sudo reboot`. |
| Touch doesn't respond | Check the touch USB cable. `lsusb` should list the screen; then `sudo systemctl restart homeos-display`. |
| Hiss or noise from the screen's speakers | In the gear menu, turn **Screen speakers** off, or lower **Volume**. The screen's own volume buttons add gain on top of that, so turn those down too. Nothing playing should go quiet after about a second. |
| No sound, or too quiet | Turn **Screen speakers** on in the gear menu and raise **Volume**. Also check the screen's own mute and volume. `speaker-test -c 2 -t wav -l 1` should say "front left, front right" through the screen. If it doesn't, `wpctl status` lists the outputs: the HDMI one should have a `*`; choose it with `wpctl set-default <number>`. |
| No sound after turning the screen on after the Pi | Sound looks for the screen's speakers when the Pi starts, and may miss them if the screen was off. Run `systemctl --user restart wireplumber`, or `sudo reboot`. |
| Videos stutter (often 4K iPhone clips) | On Raspberry Pi OS Trixie, Qt plays video through FFmpeg, which decodes on the Pi's CPU: fine for 1080p. Record at 1080p on the iPhone (Settings → Camera → Record Video). To try the Pi's HEVC decoder, add `QT_FFMPEG_DECODING_HW_DEVICE_TYPES=drm` to `display.env` and restart the app; remove it if videos get worse or go black. |
| `vcgencmd get_throttled` isn't `0x0`, or `dmesg` says `Undervoltage detected` | The Pi is short of power. Use the official 27 W supply, and power the screen from its own adapter. |
| Slow or hot (`vcgencmd measure_temp` above 80 °C) | Check that the cooler's cable is in the **FAN** connector. The fan only spins above 50 °C. |
| `homeos.local` not found, or Wi-Fi drops | Wait two minutes after power-on. Check the Wi-Fi name, password and country you set in Imager. A network cable always works. |
| Wrong time | `timedatectl` should say `System clock synchronized: yes` (it needs the internet). Set the zone with `sudo timedatectl set-timezone America/New_York` (or yours). |
| Everything too big or too small | Change `QT_SCALE_FACTOR` in `display.env`: 1.5 for this screen, 1.25 for a little more room. |
| Wrong keyboard layout or date format | Set `LANG` in `display.env`, for example `en_US.UTF-8`. |

## Try it without a Pi

### Same screen, on your computer

On Linux (or anywhere Qt 6 is installed), run the app at the panel's size:

```bash
cmake -S display -B build/display && cmake --build build/display -j
QT_SCALE_FACTOR=1 ./build/display/homeos-display --windowed   # 1280×800 window = the 10.1" layout
```

### On the Pi, before the screen is connected

`./display/deploy/preview.sh on` shows homeOS on a virtual screen that you open
in a web browser; the script prints the address. `./display/deploy/preview.sh
off` switches back to the real screen.

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

This checks the packages, the build, the install and the app. It can't
simulate the Pi's GPU, HDMI, sound or the touch panel; those only show up on
the real device.
