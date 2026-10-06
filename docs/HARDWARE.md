# Hardware

Goal: the best performance and room for custom features (sensors, voice,
camera, local AI), in a device that can later become a custom PCB.

## Recommendation: Rockchip RK3588

| | RK3588 (recommended) | Raspberry Pi 5 / CM5 | x86 mini-PC (Intel N100/N305) |
|---|---|---|---|
| CPU | 4× A76 @ 2.4 GHz + 4× A55 | 4× A76 @ 2.4 GHz | 4–8 Gracemont cores |
| GPU | Mali-G610 (Mesa Panthor, mainline) | VideoCore VII | Intel UHD |
| Video decode | 8K60 H.265/VP9/AV1, 8K30 H.264 | HEVC only, **no H.264 HW decode** | H.264/H.265/VP9/AV1 |
| NPU | 6 TOPS built in | none (needs AI HAT+) | none |
| Display outputs | HDMI 2.1, eDP, 2× MIPI-DSI | 2× HDMI, 2× MIPI-DSI | HDMI/DP |
| Custom-PCB path | Compute modules (Radxa CM5, etc.) | CM5 on a custom carrier | Hard |
| Power (typ.) | 5–12 W | 4–8 W | 10–25 W |

The RK3588 wins because family video playback needs hardware H.264 decode,
which the Pi 5 lacks. The built-in NPU also gives local face grouping for
photos, presence detection and wake-word without a cloud round trip, and the
SoC comes as a compute module for the move to a custom carrier board.

If software support matters more than peak performance, the Pi CM5 is the
fallback. The display app is plain Qt, so it runs on any of the three.

## Phase 1: prototype (off-the-shelf parts)

| Part | Suggested | Purpose |
|---|---|---|
| SBC | Radxa ROCK 5B+ or Orange Pi 5 Plus (16 GB) | Main compute |
| Storage | 256–512 GB NVMe | OS, media cache, offline data |
| Display | 21.5" 1920×1080 IPS, capacitive 10-point touch (HDMI + USB-HID) | Main screen |
| Presence | HLK-LD2410 mmWave radar (UART) | Wake the screen when someone approaches |
| Ambient light | VEML7700 (I²C) | Auto-brightness, night dimming |
| Audio out | MAX98357A I²S amp + 2× 3 W speakers | Chimes, reminders, video sound |
| Audio in | 2–4 mic array (e.g. XMOS-based USB) | Voice commands (later) |
| Camera (optional) | USB/MIPI camera with a hardware privacy shutter | Video calls, family check-in |
| Power | 12 V / 5 A barrel supply | Board + panel |

## Phase 2: custom device

- Carrier board for an RK3588 compute module: eDP or MIPI-DSI straight to an
  optically bonded panel, I²C touch controller, on-board radar, light sensor,
  I²S audio and mic array.
- Enclosure: wall mount with a recessed cable channel, or a desk stand; passive
  cooling with a heat spreader against the back plate.
- Status LED and a physical privacy switch that cuts mic and camera power.

## Software platform on the device

- **Phase 1:** Armbian / Debian with a mainline kernel (Panthor GPU driver),
  with Qt 6 rendering via EGLFS/KMS (no X11 or Wayland session needed).
- **Phase 2:** Yocto image with A/B partitions and OTA updates (RAUC or
  Mender), read-only rootfs, and the display app as a systemd service.
- Hardware access from the app:
  - backlight: `/sys/class/backlight`
  - radar: UART
  - light sensor: I²C via `/dev/i2c-*`
  - video decode: GStreamer with the Rockchip MPP plugins (`QtMultimedia`)
