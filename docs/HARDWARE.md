# Hardware

## Prototype (current build)

| Part | Chosen | Notes |
|---|---|---|
| Computer | Raspberry Pi 5, 8 GB | Runs Raspberry Pi OS (64-bit) and the Qt display app |
| Screen | JUNEBOX 10.1" IPS, 1920×1200, 5-point touch | HDMI for video, USB for touch, built-in speakers (HDMI audio) |
| Power | Official Raspberry Pi 27 W USB-C supply | Lower-rated supplies cause throttling and USB power warnings |
| Cables | Micro-HDMI → HDMI, USB-A → USB-C (touch) | The Pi 5 has micro-HDMI ports |
| Cooling | Raspberry Pi Active Cooler (recommended) | Keeps the Pi from throttling during video and long uptime |
| Storage | 64 GB+ A2 microSD (NVMe HAT + SSD later) | NVMe is faster and more durable for a 24/7 device |

The display app runs at `QT_SCALE_FACTOR=1.5` on this panel, so it lays out
for 1280×800 and switches to its compact layout. On larger screens (around 21",
1920×1080), set the scale to 1.0. See `/etc/homeos/display.env` on the device.

Setup steps: [PI_SETUP.md](PI_SETUP.md).

### Why the Pi 5

- **Software support:** Raspberry Pi OS ships the Qt 6 packages the app is
  built and tested against, and Pi documentation and community support are
  the best available.
- **Video:** iPhone videos are HEVC. The Pi 5 has an HEVC hardware decoder
  (and none for H.264), but on Raspberry Pi OS Trixie the app's video player
  (Qt 6.8 with FFmpeg) doesn't use it by default, so the CPU decodes it. That's
  fine at 1080p; 4K clips may stutter (see the troubleshooting in
  [PI_SETUP.md](PI_SETUP.md#troubleshooting)).
- **Room to grow:** GPIO, I²C and UART connect the sensors below, the AI HAT+
  adds local AI if needed, and the Compute Module 5 is the path to a custom
  board.

## Add-ons (next)

| Part | Suggested | Connects to | Purpose |
|---|---|---|---|
| Presence | HLK-LD2410 mmWave radar | UART (GPIO 14/15) | Wake the screen when someone approaches |
| Ambient light | VEML7700 | I²C (GPIO 2/3) | Auto-brightness and night dimming |
| Mic array | ReSpeaker or another XMOS USB mic | USB | Voice commands |
| Camera (optional) | Pi Camera Module 3 with a privacy shutter | CSI | Video calls, family check-in |
| AI (optional) | Raspberry Pi AI HAT+ | PCIe | Local face grouping, wake word |

Note on brightness: this panel is an HDMI monitor, so its backlight can't be
set from `/sys/class/backlight`. The app's dimming applies only to panels wired
over DSI or eDP. For an HDMI panel, the options are DDC/CI (if the monitor
supports it, via `ddcutil`) or a darker night theme. The night theme is already
in place.

## Custom device (later)

- A Compute Module 5 on a custom carrier board with a DSI or eDP panel that is
  optically bonded, an I²C touch controller, and radar, light sensor, I²S audio
  and microphones on board.
- A wall-mount enclosure with passive cooling against the back plate, plus a
  hardware privacy switch that cuts power to the mic and camera.
- A Yocto image with A/B updates over the air (RAUC or Mender), a read-only
  root filesystem and secure boot.

### Alternative board

If local AI or 8K video ever matters more than software support, Rockchip
RK3588 boards (Radxa ROCK 5B+, Orange Pi 5 Plus) have a 6 TOPS NPU and
hardware decode for every common codec. The app is plain Qt, so it ports over.
