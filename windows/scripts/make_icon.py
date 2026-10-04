#!/usr/bin/env python3
"""Renders the UAI galaxy app icon to a multi-size Windows .ico and a 512 PNG.

Mirrors the macOS icon: a spiral galaxy that fills the tile on a dark space
background (bright core, two pink/aqua arms, scattered stars).
"""
import math
import os
import sys
from PIL import Image, ImageDraw

OUT_DIR = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__)) + "/../assets"
os.makedirs(OUT_DIR, exist_ok=True)


def render(S):
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    inset = S * 0.06
    rect = (inset, inset, S - inset, S - inset)
    rw = rect[2] - rect[0]
    rx, ry = rect[0], rect[1]

    def seeded(i):
        v = math.sin(i * 12.9898) * 43758.5453
        return v - math.floor(v)

    # Rounded-tile mask.
    radius_corner = int(rw * 0.225)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(rect, radius=radius_corner, fill=255)

    # Dark space background: deep indigo corner fading to near-black.
    import numpy as np
    deepIndigo = (41, 33, 102)
    space = (10, 8, 26)
    ang = math.radians(-60)
    dx, dy = math.cos(ang), math.sin(ang)
    xs = np.arange(S)
    X, Y = np.meshgrid(xs, xs)
    proj = (X * dx + (S - Y) * dy)
    proj = (proj - proj.min()) / (proj.max() - proj.min())
    bg = np.zeros((S, S, 4), dtype=np.uint8)
    for c in range(3):
        bg[..., c] = (deepIndigo[c] * (1 - proj) + space[c] * proj).astype(np.uint8)
    bg[..., 3] = 255
    layer = Image.fromarray(bg, "RGBA")
    ld = ImageDraw.Draw(layer, "RGBA")

    cx, cy = (rect[0] + rect[2]) / 2, (rect[1] + rect[3]) / 2
    radius = rw * 0.60
    pink = (250, 115, 173)
    aqua = (128, 209, 224)

    def circle(x, y, r, color):
        ld.ellipse([x - r, y - r, x + r, y + r], fill=color)

    def radial(ccx, ccy, R, stops):
        steps = max(40, int(R))
        for k in range(steps, 0, -1):
            p = k / steps
            rr = R * p
            col = stops[-1][1]
            for j in range(len(stops) - 1):
                p0, c0 = stops[j]
                p1, c1 = stops[j + 1]
                if p0 <= p <= p1:
                    f = (p - p0) / (p1 - p0 + 1e-9)
                    col = tuple(int(c0[m] + (c1[m] - c0[m]) * f) for m in range(4))
                    break
            ld.ellipse([ccx - rr, ccy - rr, ccx + rr, ccy + rr], fill=col)

    # Stars.
    for i in range(60):
        x = rx + seeded(i * 7) * rw
        y = ry + seeded(i * 13) * rw
        s = S * 0.004 + seeded(i) * S * 0.012
        a = int((0.25 + seeded(i * 3) * 0.5) * 255)
        circle(x, y, s / 2, (255, 255, 255, a))

    # Halo + bright core.
    radial(cx, cy, radius * 0.95, [(0.0, (120, 97, 219, 77)), (0.5, (250, 115, 173, 20)), (1.0, (0, 0, 0, 0))])
    radial(cx, cy, radius * 0.30, [(0.0, (255, 255, 255, 255)), (0.55, (250, 115, 173, 217)), (1.0, (0, 0, 0, 0))])

    # Two tilted spiral arms of glowing dots.
    tilt = math.pi / 9
    cosT, sinT = math.cos(tilt), math.sin(tilt)
    flatten = 0.72
    for offset, color in [(0.0, pink), (math.pi, aqua)]:
        for i in range(140):
            t = i / 140
            angle = offset + t * 3.4 * math.pi
            r = radius * (0.10 + 0.90 * t)
            jitter = (seeded(i + int(offset * 100)) - 0.5) * radius * 0.08
            px = math.cos(angle) * (r + jitter)
            py = math.sin(angle) * (r + jitter) * flatten
            x = cx + px * cosT - py * sinT
            y = cy + px * sinT + py * cosT
            dot = radius * (0.075 - 0.045 * t)
            shade = (255, 255, 255) if t < 0.22 else color
            a = int((0.95 - 0.45 * t) * 255)
            circle(x, y, dot / 2, (shade[0], shade[1], shade[2], a))

    return Image.composite(layer, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask)


big = render(512)
big.save(os.path.join(OUT_DIR, "icon.png"))
# Windows .ico with the sizes Explorer/taskbar use.
sizes = [16, 24, 32, 48, 64, 128, 256]
imgs = {s: render(s) for s in sizes}
imgs[256].save(os.path.join(OUT_DIR, "icon.ico"),
               sizes=[(s, s) for s in sizes],
               append_images=[imgs[s] for s in sizes if s != 256])
print("wrote icon.ico and icon.png to", OUT_DIR)
