# Setting up the Ohana display (Raspberry Pi 5 + 10.1" touchscreen)

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
   **Next**. Lite has no desktop, so Ohana is the only thing on the screen.
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

Turn the screen on before the Pi when you can. If it comes on later, Ohana
appears a few seconds after it does, but its sound may not work until the Pi
restarts (see [Troubleshooting](#troubleshooting)).

Mount the screen in landscape. Portrait or upside-down mounting isn't
supported yet.

## 3. Install Ohana

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
```

The script enables `homeos-display` and starts it before it exits. When it
finishes, `systemctl is-active homeos-display` prints `active` and the panel
shows Ohana. Run it over SSH like this. Run from a login on the panel itself,
it ends when Ohana takes that console; Ohana still starts, but finish an
update with another run over SSH. `journalctl -u homeos-display -f` only shows logs. It does not
start the app and it does not draw on HDMI.

Reboot once after that. A reboot applies the console options from the script,
and it is the check that a later power-on brings Ohana back by itself:

```bash
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
- installs Qt 6, ffmpeg (for the HEVC decoder check), PipeWire (for sound) and
  fonts, then builds and installs the app to `/usr/local/bin/homeos-display`
- finds the HDMI output (`/etc/homeos/kms.json`) and writes the settings file
  `/etc/homeos/display.env` (kept when you re-run it)
- checks the Pi 5 HEVC decoder against the CPU and records the result in
  `display.env` (see [Video decoding](#video-decoding))
- quiets the panel for the next reboot: no rainbow splash, no Plymouth
  splash, no blinking cursor or screen blanking, and no boot text. Kernel
  messages, disk checks and anything else written to the console go to
  `tty3`, which is never on the panel (`/boot/firmware/cmdline.txt` and
  `config.txt`; the originals are saved as `cmdline.txt.homeos-backup` and
  `config.txt.homeos-backup`). Cloud-init's boot notes go to its log. The
  panel stays black until Ohana draws its boot screen. SSH is unchanged
- sends sound to the screen's speakers at half volume (full volume on this
  panel is mostly hiss; the gear menu turns the speakers off or up, and the
  screen's own buttons still work), and turns off Wi-Fi power saving, which
  makes Wi-Fi drop out
- writes `/etc/ssh/sshd_config.d/homeos.conf` (`IPQoS cs0 cs0` and `UseDNS no`)
  and reloads ssh, so typing in a terminal does not stutter over Wi-Fi. That
  applies in the current session; it does not need a reboot
- enables and starts the `homeos-display` service, which takes the console on
  every boot so the screen shows Ohana instead of a login prompt
- warns at the end if the Pi has been short of power

## 4. What you should see

When the install script finishes, Ohana should already be on the screen.
Check with `systemctl is-active homeos-display`. A healthy service prints
`active`. Reboot once after that. The reboot applies quiet boot, and it is
the check that a later power-on brings Ohana back by itself.

After the reboot, the panel shows no text at all: it stays black while the
Pi starts, then the boot screen (the logo) fades in. The logo stays at least
5 seconds, and longer while Ohana fetches the family's first data (up to 15
seconds, if Wi-Fi is slow to connect), then fades into the app. Ohana draws
the boot screen itself, so nothing hands the screen over in the middle and
no console shows in between. SSH works the whole time. The console login on
the panel is masked; **Everyday commands** below shows how to get it back.

To change how long the logo stays, set `HOMEOS_BOOT_SECONDS` in
`/etc/homeos/display.env` (`0` turns the boot screen off) and run
`sudo systemctl restart homeos-display`.

`journalctl -u homeos-display -f` only shows logs. It does not start Ohana.
If the panel is showing a terminal, put Ohana on HDMI with:

```bash
sudo systemctl enable --now homeos-display
systemctl is-active homeos-display
```

`active` means the service has the screen. If that command says the unit
could not be found, the install script has not finished. Run it again:

```bash
cd ~/homeOS
git pull
./display/deploy/install-pi.sh
sudo reboot
```

If `systemctl is-active homeos-display` stays something other than `active`,
read why it exited. This only prints logs:

```bash
journalctl -u homeos-display -b --no-pager
```

If the service is `active` and the panel still shows a terminal, the process
is up but it did not open the HDMI device. The same journal command shows
`Could not open DRM device`, `No modes available`, or `no screen`. Then check
`cat /etc/homeos/kms.json` against `ls -l /dev/dri/by-path/` and re-run
`./display/deploy/install-pi.sh` so it points Qt at the HDMI port.

The boot screen is drawn from `display/resources/boot/` (regenerate it with
`make-boot-screen.py` there). To play a video in its place, copy it to
`/etc/homeos/boot.mp4` and reboot. That file is kept when you re-run the
installer; remove it to go back to the logo. 1920×1200 (or 1920×1080), a few
seconds. It plays muted, through to the end at least once, and loops if
Ohana needs longer. A file that does not play falls back to the logo.

The admin console (Settings → Boot video) can set one short silent MP4 for
every display. If `/etc/homeos/display.env` has `HOMEOS_SUPABASE_URL` and
`HOMEOS_SUPABASE_ANON_KEY`, the Pi checks for it in the background
(`homeos-boot-video-sync.timer`): a couple of minutes after boot, once the
network is up, and every six hours after that. A new video is downloaded to
`/var/lib/homeos/boot.mp4` and plays from the next boot; the boot itself never
waits for Wi-Fi. To check right away, run
`sudo systemctl start homeos-boot-video-sync`. A file you copied to
`/etc/homeos/boot.mp4` still wins, and the download does not overwrite it.
Until the first download, the logo shows. A failed check keeps the last
video. Removing the video in admin deletes the cached copy at the next
check, and the logo shows from the boot after that.

Tap the chores and rewards to try it. Videos under **Media** play with sound
from the screen's speakers. After two minutes without a touch, the photo
frame starts; a tap wakes it. A video playing in the viewer counts as a
touch, so a long one isn't cut off.

## 5. Connect it to your family

Until the backend is set up, the display shows sample data. Once there's a
Supabase project (see the main README):

1. Run `sudo nano /etc/homeos/display.env` and set `HOMEOS_SUPABASE_URL` and
   `HOMEOS_SUPABASE_ANON_KEY` (remove the `#` in front of each). Set
   `HOMEOS_MEDIA_URL` to the admin app's origin so photos and videos stored
   in Blob (everything new) can show; older files in Storage show without it.
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

This downloads about 220 MB of speech models and starts the voice service on
every boot, as the same user as the display. Spoken replies use the screen
speakers: the gear menu's **Screen speakers** switch and **Volume** apply to
them. Without a microphone yet, check the speakers with
`/opt/homeos-voice/bin/python -m homeos_voice --say "Hello from Ohana"`.
Once a USB mic is plugged in, say "Hey Jarvis" and ask a question. You can
also install voice together with the display:
`./display/deploy/install-pi.sh --with-voice` (add `--skip-models` to fetch the
models later). Details and voice troubleshooting: [VOICE.md](VOICE.md).

## Video decoding

On Raspberry Pi OS Trixie, Qt plays video through FFmpeg. HEVC, which the
iPhone app uploads, decodes on the Pi 5's HEVC block through Raspberry Pi's
FFmpeg `drm` hwaccel. H.264 always decodes on the CPU (the Pi 5 has no
H.264 block); that is fine at 1080p. On Bookworm (Qt 6.4) video goes through
GStreamer instead, and nothing in this section applies.

The setting is `QT_FFMPEG_DECODING_HW_DEVICE_TYPES` in
`/etc/homeos/display.env`:

| Value | Effect |
|---|---|
| `drm` | HEVC decodes on the HEVC block. A stream it can't take (H.264, 4:2:2, 12-bit) falls back to the CPU by itself. |
| `,` | Everything decodes on the CPU. This is the off switch. |
| not set | The app uses `drm` when it runs on the panel. |

Qt reads it once, at the first video, so restart the app after a change.

**The installer's check.** On a Pi 5 running Trixie, `install-pi.sh` makes
two 1-second HEVC test clips (8-bit and 10-bit), decodes each on the HEVC
block and on the CPU, and compares the frames. It writes the result with a
comment above it:

```
# set by install-pi.sh hevc self-test: drm
QT_FFMPEG_DECODING_HW_DEVICE_TYPES=drm
```

The install output says `HEVC hardware decoding works`, or that it failed
its check, in which case it writes `,` in place of `drm`. If it could not
test at all (no test clip, say), it writes nothing. Each install tests again
and replaces its own line. A value you wrote yourself, or the installer's
line after you change its value, is kept. The check is skipped on Bookworm,
and where there is no HEVC decoder (not a Pi 5).

**Turn hardware decoding off** if videos go black, show wrong colors, or
play worse than on the CPU:

```bash
sudo nano /etc/homeos/display.env   # set QT_FFMPEG_DECODING_HW_DEVICE_TYPES=,
sudo systemctl restart homeos-display
```

To hand the choice back to the installer, delete that line and the comment
above it. The app then uses `drm`, and the next install tests again.

**Check that it works.** The expected output below comes from reading the Qt
and FFmpeg sources; it has not been confirmed on a Pi yet.

1. Packages: `dpkg-query -W libavcodec61 libqt6multimedia6`. The
   `libavcodec61` version should contain `+rpt` (Raspberry Pi's build; the
   installer warns if it doesn't), and Qt should be 6.8.
   `ls /usr/lib/aarch64-linux-gnu/qt6/plugins/multimedia/` should list
   `libffmpegmediaplugin.so`.
2. The decoder: `ffmpeg -hide_banner -hwaccels` lists `drm`.
   `v4l2-ctl --list-devices` (the installer adds `v4l-utils`) lists the HEVC
   decoder (`rpi-hevc-dec`) with a `/dev/videoN` and a `/dev/mediaN`.
   `cat /sys/class/video4linux/video*/name` shows the name the installer
   looks for.
3. The setting: `grep QT_FFMPEG /etc/homeos/display.env` should show `drm`.
4. The app's log, after playing a video:

   ```bash
   journalctl -u homeos-display -b -o cat | grep -E 'homeOS display:|Hwaccel V4L2 HEVC|Failed to open FFmpeg codec context|Error transferring|Cannot map a video frame'
   ```

   - `homeOS display: video decoding: drm` (`CPU only` after the off switch).
   - `homeOS display: drawing on V3D ...`: Qt Quick draws on the GPU. A line
     that says `in software` means it doesn't.
   - `Hwaccel V4L2 HEVC stateless ...` once for each HEVC video opened: that
     video decodes on the HEVC block.
   - `Failed to open FFmpeg codec context` for an H.264 video, followed by
     normal playback, is expected: there is no H.264 block, so it falls back
     to the CPU.
   - `Error transferring the data to system memory` or
     `Cannot map a video frame` means the hardware path failed. Use the off
     switch.
5. CPU use: run `top -H -p $(pidof homeos-display)` while a video plays,
   once with `drm` and once with `,`.

For more detail, add this line to `display.env`, restart, and play a video.
`Selected format 178 for hw 8` means the HEVC block is in use. Remove the
line afterwards; it is noisy.

```
QT_LOGGING_RULES="qt.multimedia.ffmpeg.hwaccel.debug=true;qt.multimedia.playbackengine.codec.debug=true"
```

## Everyday commands

| Task | Command |
|---|---|
| Put Ohana on the HDMI panel | `sudo systemctl enable --now homeos-display` |
| Check that the panel app is running | `systemctl is-active homeos-display` (prints `active`) |
| Read logs (does not start the screen) | `journalctl -u homeos-display -f` |
| Read logs when the service stays inactive | `journalctl -u homeos-display -b --no-pager` |
| Restart the app | `sudo systemctl restart homeos-display` |
| Change Wi-Fi, volume, restart or reboot | On the screen, tap the gear. Wi-Fi and reboot need the helper from the install script |
| Change app settings | `sudo nano /etc/homeos/display.env`, then restart the app |
| Update to the latest code | `cd ~/homeOS && git pull && ./display/deploy/install-pi.sh` (updates the voice service too, if installed) |
| Get a login prompt on the screen | `sudo systemctl stop homeos-display && sudo systemctl unmask getty@tty1.service autovt@tty1.service && sudo systemctl start getty@tty1` (install masks those units so a boot cannot stick on the console; re-run `install-pi.sh` or `preview.sh off` to mask them again) |
| Use your own boot video | Set it under **Settings → Boot video** in the admin console. The Pi downloads it within six hours (or now: `sudo systemctl start homeos-boot-video-sync`) and plays it from the next reboot. Or `sudo cp my-video.mp4 /etc/homeos/boot.mp4` and reboot; that file wins over the admin video. Delete it to use the admin video, or remove the admin video to go back to the logo |
| Change how long the boot logo stays | `HOMEOS_BOOT_SECONDS=8` in `/etc/homeos/display.env` (default 5, `0` turns the boot screen off), then restart the app |
| Check power and temperature | `vcgencmd get_throttled` (`0x0` is good) and `vcgencmd measure_temp` |

## Troubleshooting

`journalctl -u homeos-display -f` only shows logs. It does not start Ohana and it does not draw on the panel. To put Ohana on HDMI:

```bash
sudo systemctl enable --now homeos-display
```

`systemctl is-active homeos-display` prints `active` when that worked. Use the journal only when it stays inactive, or when it is `active` and the panel is still a terminal:

```bash
journalctl -u homeos-display -b --no-pager
```

| Symptom | Fix |
|---|---|
| A terminal or login prompt is on the screen | `journalctl` will not change the picture. Run `sudo systemctl enable --now homeos-display`. `systemctl is-active homeos-display` should print `active`, and `systemctl is-enabled homeos-display` should print `enabled`. If the unit could not be found, or a login prompt comes back after a reboot, re-run `./display/deploy/install-pi.sh`, then `sudo reboot`. It enables and starts `homeos-display`, masks `getty@tty1` / `autovt@tty1` (`systemctl is-enabled getty@tty1` should say `masked`), and applies quiet boot. If it stays inactive, `journalctl -u homeos-display -b --no-pager` shows why. |
| The service is `active` but the panel is still a terminal | The app did not open the HDMI device. `journalctl -u homeos-display -b --no-pager` and `cat /etc/homeos/kms.json`. The device should be one of `ls -l /dev/dri/by-path/`, and the output name should be `HDMI1` for the HDMI0 port (kernel name `HDMI-A-1`). Re-run `./display/deploy/install-pi.sh`. |
| Boot text, the rainbow square, or `Completed socket interaction for boot stage final` stays on the screen | Re-run `./display/deploy/install-pi.sh`, then `sudo reboot`. `/boot/firmware/cmdline.txt` should have `console=tty3` (not `console=tty1`) and `quiet`, `disable_splash=1` is in `/boot/firmware/config.txt`, and cloud-init is sent to the log (`/etc/cloud/cloud.cfg.d/99-homeos-quiet.cfg`). The cloud-init line is a successful boot note, not a hang. Boot text lands on `tty3`: with a keyboard, Ctrl+Alt+F3 shows it (an emergency shell opens there too) and Ctrl+Alt+F1 goes back. |
| The panel stays black after boot | The boot screen is drawn by the app, so black means the app has not started yet or keeps exiting. `systemctl is-active homeos-display`, then `journalctl -u homeos-display -b --no-pager`. A black panel that never shows the logo is the same check as a terminal on the screen (above). |
| The boot logo stays up for a long time | It waits up to 15 seconds for the family's first data. If Wi-Fi is down it gives up then and shows Ohana with **Offline — reconnecting…**. |
| A boot video from an older install stays up over Ohana | Re-run `./display/deploy/install-pi.sh`. It removes the old `homeos-bootscreen` player, which nothing stops any more. Right now: `sudo systemctl disable --now homeos-bootscreen`. |
| The admin's boot video does not play | `journalctl -u homeos-boot-video-sync` shows each check. `sudo systemctl start homeos-boot-video-sync` checks now; restart the app or reboot after it says the video was downloaded. A file at `/etc/homeos/boot.mp4` wins over the admin video. A video that does not play shows the logo instead; `journalctl -u homeos-display -b` has the player's error. |
| Boot messages stay on the screen, and the log repeats `No modes available`, `Could not open DRM device` or a crash | The app can't find the screen and retries every second. Check that the cable is in **HDMI0** and the screen is on and set to HDMI. `cat /etc/homeos/kms.json` should name a device from `ls -l /dev/dri/by-path/`; re-run `./display/deploy/install-pi.sh` to detect it again. |
| The gear menu says it isn't allowed to change Wi-Fi | Re-run `./display/deploy/install-pi.sh`. It installs `/usr/local/libexec/homeos-system` and lets your user run that, and only that, without a password. |
| `Permission denied` for `/dev/dri` or `/dev/input` in the log | Run `groups`: it should list `video render input audio tty`. Re-run the install script, then `sudo reboot`. |
| Touch doesn't respond | Check the touch USB cable. `lsusb` should list the screen; then `sudo systemctl restart homeos-display`. |
| Hiss or noise from the screen's speakers | In the gear menu, turn **Screen speakers** off, or lower **Volume**. The screen's own volume buttons add gain on top of that, so turn those down too. Nothing playing should go quiet after about a second. |
| No sound, or too quiet | Turn **Screen speakers** on in the gear menu and raise **Volume**. Also check the screen's own mute and volume. `speaker-test -c 2 -t wav -l 1` should say "front left, front right" through the screen. If it doesn't, `wpctl status` lists the outputs: the HDMI one should have a `*`; choose it with `wpctl set-default <number>`. |
| No sound after turning the screen on after the Pi | Sound looks for the screen's speakers when the Pi starts, and may miss them if the screen was off. Run `systemctl --user restart wireplumber`, or `sudo reboot`. |
| Videos stutter (often 4K iPhone clips) | The iPhone app now uploads videos at 1080p or less, mostly HEVC, which the Pi decodes on its HEVC block. Clips uploaded before that are often 4K and can still stutter; add them again from the phone and delete the old copy. Check the setting and the log as in [Video decoding](#video-decoding). If videos go black or look worse with `drm`, set `QT_FFMPEG_DECODING_HW_DEVICE_TYPES=,` in `display.env` and run `sudo systemctl restart homeos-display`. |
| `vcgencmd get_throttled` isn't `0x0`, or `dmesg` says `Undervoltage detected` | The Pi is short of power. Use the official 27 W supply, and power the screen from its own adapter. |
| Slow or hot (`vcgencmd measure_temp` above 80 °C) | Check that the cooler's cable is in the **FAN** connector. The fan only spins above 50 °C. |
| `homeos.local` not found, or Wi-Fi drops | Wait two minutes after power-on. Check the Wi-Fi name, password and country you set in Imager. A network cable always works. |
| Typing lags in an SSH terminal | Re-run `./display/deploy/install-pi.sh`, or write `IPQoS cs0 cs0` and `UseDNS no` to `/etc/ssh/sshd_config.d/homeos.conf` and run `sudo systemctl reload ssh`. Stay in this session; a reboot is not required. That fixes the stutter even when the Pi is idle. If keystrokes still stutter, run `top`: a `homeos-display` restart loop pegging a core is a different problem. |
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

`./display/deploy/preview.sh on` shows Ohana on a virtual screen that you open
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
