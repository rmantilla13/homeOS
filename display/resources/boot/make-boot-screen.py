#!/usr/bin/env python3
"""Regenerate the boot screen layers in display/resources/boot/.

The homeOS boot screen: warm canvas (#F1EFEB), the day-palette glow arch
(blue, coral, amber), a house mark and the homeOS wordmark. The app draws it
itself (qml/screens/BootScreen.qml), so it is three PNGs for a 1920x1200
stage rather than a video:

  background.png  canvas and arch
  highlight.png   the soft light that drifts along the arch
  mark.png        house and wordmark on transparent

Needs python3, numpy, ffmpeg, and an Inter Medium font (the fonts-inter
package, or any Inter-Medium file on the font path). The build embeds the
PNGs this writes; you do not need to run this on the Pi.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np

# Keep these in step with BootScreen.qml.
W, H = 1920, 1200
# Circle whose top sits under the wordmark. Screen y grows downward, so the
# top of the circle is cy - r.
CX, CY, R = 960.0, 1460.0, 740.0
ARCH_SIGMA = 88.0
ARCH_PEAK = 0.42
HOUSE_Y = 248
WORDMARK_Y = 608
CANVAS = np.array([241, 239, 235], np.float32)  # #F1EFEB
INK = np.array([28, 28, 31], np.float32)  # #1C1C1F

# Same stops as the day glow in display/qml/Theme.qml.
STOPS = (
    (0.00, np.array([91, 124, 245], np.float32)),   # #5B7CF5
    (0.40, np.array([240, 127, 90], np.float32)),   # #F07F5A
    (0.72, np.array([246, 185, 74], np.float32)),   # #F6B94A
    (1.00, np.array([251, 230, 176], np.float32)),  # #FBE6B0
)


def find_font() -> str:
    env = os.environ.get("HOMEOS_BOOT_FONT")
    candidates = [
        env,
        "/usr/share/fonts/truetype/inter/Inter-Medium.otf",
        "/usr/share/fonts/truetype/inter/Inter-Medium.ttf",
        "/usr/share/fonts/opentype/inter/Inter-Medium.otf",
        "/usr/share/fonts/truetype/macos/Inter-Medium.ttf",
    ]
    for path in candidates:
        if path and os.path.isfile(path):
            return path
    if shutil.which("fc-list"):
        out = subprocess.check_output(
            ["fc-list", "Inter:style=Medium", "file"], text=True
        )
        for line in out.splitlines():
            path = line.split(":", 1)[0].strip()
            if path and os.path.isfile(path) and "Italic" not in path:
                return path
    sys.exit("Inter Medium was not found. Install fonts-inter or set HOMEOS_BOOT_FONT.")


def gradient_row() -> np.ndarray:
    t = np.linspace(0.0, 1.0, W, dtype=np.float32)
    rgb = np.empty((W, 3), np.float32)
    rgb[:] = STOPS[-1][1]
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        mask = (t >= t0) & (t <= t1)
        u = (t[mask] - t0) / (t1 - t0)
        rgb[mask] = c0 + (c1 - c0) * u[:, None]
    return rgb


def render_background() -> np.ndarray:
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    dist = np.hypot(xs - CX, ys - CY)
    alpha = np.exp(-0.5 * ((dist - R) / ARCH_SIGMA) ** 2) * ARCH_PEAK
    # Keep the arch a cradle under the wordmark, not a ring across the top.
    alpha *= np.clip((ys - 620.0) / 80.0, 0.0, 1.0)
    colors = gradient_row()[None, :, :]
    out = CANVAS + (colors - CANVAS) * alpha[:, :, None]
    return np.clip(np.rint(out), 0, 255).astype(np.uint8)


def arc_points(cx, cy, radius, a0, a1, n=12):
    pts = []
    for i in range(n + 1):
        a = a0 + (a1 - a0) * i / n
        pts.append((cx + radius * np.cos(a), cy + radius * np.sin(a)))
    return pts


def house_segments():
    # The wall-display icon's house, in its 64px viewBox, stroke only.
    right = arc_points(43, 45, 3, 0, np.pi / 2)
    left = arc_points(21, 45, 3, np.pi / 2, np.pi)
    pts = [(18, 31.5), (32, 20), (46, 31.5), (46, 45)]
    pts.extend(right[1:])
    pts.append((21, 48))
    pts.extend(left[1:])
    pts.append((18, 31.5))
    return list(zip(pts, pts[1:]))


def render_house() -> np.ndarray:
    """Coverage (0..1) of the house stroke, in a tight bitmap."""
    scale = 9.0
    pad = 8.0
    minx, miny, maxx, maxy = 18.0, 20.0, 46.0, 48.0
    width = int(round((maxx - minx + 2 * pad) * scale))
    height = int(round((maxy - miny + 2 * pad) * scale))
    ox = (pad - minx) * scale
    oy = (pad - miny) * scale
    radius = (4.6 / 2) * scale
    ys, xs = np.mgrid[0:height, 0:width].astype(np.float32)
    mind = np.full((height, width), 1e9, np.float32)
    for (x0, y0), (x1, y1) in house_segments():
        x0 = x0 * scale + ox
        y0 = y0 * scale + oy
        x1 = x1 * scale + ox
        y1 = y1 * scale + oy
        vx, vy = x1 - x0, y1 - y0
        length2 = vx * vx + vy * vy
        t = np.clip(((xs - x0) * vx + (ys - y0) * vy) / length2, 0.0, 1.0)
        dist = np.hypot(xs - (x0 + t * vx), ys - (y0 + t * vy))
        mind = np.minimum(mind, dist)
    aa = 1.35
    alpha = np.clip((radius + aa - mind) / (2 * aa), 0.0, 1.0)
    return np.where(mind <= radius - aa, 1.0, alpha).astype(np.float32)


def render_highlight() -> np.ndarray:
    size = 560
    ys, xs = np.mgrid[0:size, 0:size].astype(np.float32)
    dist = np.hypot(xs - size / 2, ys - size / 2)
    alpha = np.exp(-0.5 * (dist / 108.0) ** 2) * 0.62
    rgba = np.zeros((size, size, 4), np.uint8)
    rgba[:, :, 0] = 255
    rgba[:, :, 1] = 246
    rgba[:, :, 2] = 230
    rgba[:, :, 3] = np.clip(np.rint(alpha * 255), 0, 255).astype(np.uint8)
    return rgba


def draw_wordmark(stage: np.ndarray, font: str, tmp: str) -> np.ndarray:
    """The stage with the wordmark drawn on it by ffmpeg (freetype)."""
    src = os.path.join(tmp, "stage.rgb")
    dst = os.path.join(tmp, "text.rgb")
    stage.tofile(src)
    subprocess.check_call([
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{W}x{H}", "-i", src,
        "-vf", (
            f"drawtext=fontfile='{font}':text='homeOS':fontsize=116:"
            f"fontcolor=0x1C1C1F:x=(w-text_w)/2:y={WORDMARK_Y}"
        ),
        "-frames:v", "1", "-f", "rawvideo", "-pix_fmt", "rgb24", dst,
    ])
    return np.fromfile(dst, np.uint8).reshape(H, W, 3).astype(np.float32)


def render_mark(font: str, tmp: str) -> np.ndarray:
    # Ink over black and over white: the difference between the two is how
    # much of each pixel the ink covers.
    house = render_house()
    hh, hw = house.shape
    hx = (W - hw) // 2
    shots = []
    for bg in (0.0, 255.0):
        stage = np.full((H, W, 3), bg, np.float32)
        region = stage[HOUSE_Y:HOUSE_Y + hh, hx:hx + hw]
        region[:] = INK + (region - INK) * (1.0 - house[:, :, None])
        stage = np.clip(np.rint(stage), 0, 255).astype(np.uint8)
        shots.append(draw_wordmark(stage, font, tmp))
    black, white = shots
    coverage = 1.0 - (white - black).mean(axis=2) / 255.0
    rgba = np.zeros((H, W, 4), np.uint8)
    rgba[:, :, :3] = INK.astype(np.uint8)
    rgba[:, :, 3] = np.clip(np.rint(coverage * 255), 0, 255).astype(np.uint8)
    return rgba


def write_png(pixels: np.ndarray, path: str, tmp: str) -> None:
    height, width, channels = pixels.shape
    fmt = "rgba" if channels == 4 else "rgb24"
    raw = os.path.join(tmp, "layer.raw")
    pixels.tofile(raw)
    subprocess.check_call([
        "ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f", "rawvideo", "-pix_fmt", fmt, "-s", f"{width}x{height}", "-i", raw,
        "-frames:v", "1", "-pix_fmt", fmt, "-pred", "mixed", path,
    ])
    print(f"wrote {path} ({os.path.getsize(path)} bytes)")


def main() -> None:
    out = os.path.dirname(os.path.abspath(__file__))
    font = find_font()
    with tempfile.TemporaryDirectory() as tmp:
        write_png(render_background(), os.path.join(out, "background.png"), tmp)
        write_png(render_highlight(), os.path.join(out, "highlight.png"), tmp)
        write_png(render_mark(font, tmp), os.path.join(out, "mark.png"), tmp)
    print(f"font {font}")


if __name__ == "__main__":
    main()
