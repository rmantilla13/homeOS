#!/usr/bin/env python3
"""Rasterize the homeOS mark (admin/app/icon.svg) to the iOS app icon.

The glyph is the same house stroke on the same blue → coral → amber gradient.
iOS masks the corners, so this image is a full-bleed square with no alpha.
"""

import math
import struct
import zlib
from pathlib import Path

SIZE = 1024
SCALE = SIZE / 64
STROKE = 4 * SCALE
STOPS = (
    (0.0, (0x5B, 0x7C, 0xF5)),
    (0.55, (0xF0, 0x7F, 0x5A)),
    (1.0, (0xF6, 0xB9, 0x4A)),
)


def house_points() -> list[tuple[float, float]]:
    pts = [(18, 31.5), (32, 20), (46, 31.5), (46, 45)]
    for i in range(1, 9):
        a = (i / 8) * math.pi / 2
        pts.append((43 + 3 * math.cos(a), 45 + 3 * math.sin(a)))
    pts.append((21, 48))
    for i in range(1, 9):
        a = (i / 8) * math.pi / 2
        pts.append((21 - 3 * math.sin(a), 45 + 3 * math.cos(a)))
    pts.append((18, 31.5))
    return [(x * SCALE, y * SCALE) for x, y in pts]


def gradient(x: int, y: int) -> tuple[int, int, int]:
    t = (x + y) / (2 * (SIZE - 1))
    for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
        if t <= t1:
            u = 0 if t1 == t0 else (t - t0) / (t1 - t0)
            return tuple(round(a + (b - a) * u) for a, b in zip(c0, c1))  # type: ignore[return-value]
    return STOPS[-1][1]


def seg_dist(px: float, py: float, ax: float, ay: float, bx: float, by: float) -> float:
    dx, dy = bx - ax, by - ay
    len2 = dx * dx + dy * dy
    if len2 == 0:
        return math.hypot(px - ax, py - ay)
    u = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / len2))
    return math.hypot(px - (ax + u * dx), py - (ay + u * dy))


def png(rgb: bytes) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + rgb[y * SIZE * 3:(y + 1) * SIZE * 3] for y in range(SIZE))
    ihdr = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")


def main() -> None:
    pts = house_points()
    segments = list(zip(pts, pts[1:]))
    pad = int(STROKE)
    xs = [p[0] for p in pts]
    ys = [p[1] for p in pts]
    min_x = max(0, int(min(xs)) - pad)
    max_x = min(SIZE - 1, int(max(xs)) + pad)
    min_y = max(0, int(min(ys)) - pad)
    max_y = min(SIZE - 1, int(max(ys)) + pad)
    radius = STROKE / 2
    buf = bytearray(SIZE * SIZE * 3)
    for y in range(SIZE):
        row = y * SIZE * 3
        for x in range(SIZE):
            r, g, b = gradient(x, y)
            if min_x <= x <= max_x and min_y <= y <= max_y:
                px, py = x + 0.5, y + 0.5
                dist = min(seg_dist(px, py, a[0], a[1], b[0], b[1]) for a, b in segments)
                t = max(0.0, min(1.0, radius + 0.75 - dist))
                if t:
                    r = round(r + (255 - r) * t)
                    g = round(g + (255 - g) * t)
                    b = round(b + (255 - b) * t)
            buf[row + x * 3:row + x * 3 + 3] = bytes((r, g, b))
    out = Path(__file__).resolve().parents[1] / "HomeOS" / "Assets.xcassets" / "AppIcon.appiconset" / "AppIcon.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    data = png(bytes(buf))
    out.write_bytes(data)
    print(f"{out} {len(data)} bytes")


if __name__ == "__main__":
    main()
