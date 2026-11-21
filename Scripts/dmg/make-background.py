#!/usr/bin/env python3
"""Render the DMG window background (1x + 2x): soft color glows plus an ASCII voice waveform
that flows from the app icon into Applications.

Dev-time only (needs Pillow); the rendered background.tiff is committed so CI needs nothing.
Run from the repo root: python3 Scripts/dmg/make-background.py
"""
import math
import os
import random
import subprocess
import tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Must match the icon positions and window size in Scripts/build-dmg.sh.
W, H = 640, 400
APP_X, APPS_X, ICON_Y = 170, 470, 200
LABEL_Y = ICON_Y + 82  # Finder draws the icon names here; keep it clear.

CANVAS = (244, 245, 241)
INK = (32, 32, 30)
GRAPHITE = (100, 107, 120)
SIGNAL = (47, 76, 221)
VIOLET = (158, 97, 235)
WARM = (255, 158, 97)

FONTS = os.path.join(os.path.dirname(__file__), "../../Resources/Fonts")
HERE = os.path.dirname(os.path.abspath(__file__))
RAMP = " .·:;+=*#%@"


def mix(a, b, t):
    return tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(t):
    """Signal blue -> violet -> warm along the window."""
    return mix(SIGNAL, VIOLET, t * 2) if t < 0.5 else mix(VIOLET, WARM, (t - 0.5) * 2)


def amplitude(x):
    """Speech-like envelope: syllable bumps, loudest between the icons, fading at the edges."""
    u = x / W
    syllables = sum(a * math.exp(-((u - c) / w) ** 2) for a, c, w in
                    [(0.55, 0.30, 0.05), (0.9, 0.42, 0.06), (1.0, 0.52, 0.05), (0.75, 0.62, 0.06),
                     (0.45, 0.72, 0.05), (0.3, 0.16, 0.06), (0.25, 0.86, 0.06)])
    # Per-column variation so it reads as a voice waveform, not a block.
    col = int(x // 6)
    noise = abs(math.sin(col * 12.9898) * 43758.5453) % 1.0
    return 3 + 58 * min(1.0, syllables + 0.12) * (0.3 + 0.7 * noise)


def keep_clear(x, y):
    """0 inside the icon and label areas, fading to 1 outside."""
    m = 1.0
    for cx in (APP_X, APPS_X):
        d = math.hypot(x - cx, (y - ICON_Y) * 1.1)
        m = min(m, max(0.0, min(1.0, (d - 70) / 22)))
        if abs(y - LABEL_Y) < 14 and abs(x - cx) < 70:
            m = 0.0
    return m


def render(scale):
    s = lambda v: round(v * scale)
    img = Image.new("RGB", (s(W), s(H)), CANVAS)

    # Soft color glows, very low contrast so Finder labels stay readable in both appearances.
    glow = Image.new("RGB", img.size, CANVAS)
    g = ImageDraw.Draw(glow)
    for (cx, cy, r, color) in [(-40, -60, 260, SIGNAL), (W + 40, H + 40, 280, WARM), (W * 0.62, -90, 200, VIOLET)]:
        g.ellipse([s(cx - r), s(cy - r), s(cx + r), s(cy + r)], fill=mix(CANVAS, color, 0.22))
    img = Image.blend(img, glow.filter(ImageFilter.GaussianBlur(s(90))), 1.0)
    d = ImageDraw.Draw(img)

    mono = ImageFont.truetype(f"{FONTS}/FragmentMono-Regular.ttf", s(8))
    rng = random.Random(7)
    cw, ch = 6, 8  # cell size at 1x

    for row in range(H // ch + 1):
        y = row * ch + ch / 2
        for col in range(W // cw + 1):
            x = col * cw + cw / 2
            clear = keep_clear(x, y)
            if abs(x - (APPS_X - 90)) < 12 and abs(y - ICON_Y) < 14:
                continue  # room for the arrowhead
            if clear <= 0:
                continue
            amp = amplitude(x)
            dy = abs(y - ICON_Y)
            wave = max(0.0, 1 - dy / amp) ** 1.4 if dy < amp else 0.0
            dust = 0.12 if rng.random() < 0.05 else 0.0  # sparse ambient grain
            v = max(wave, dust) * clear
            if v < 0.06:
                continue
            glyph = RAMP[min(len(RAMP) - 1, int(v * (len(RAMP) - 1) + rng.random() * 0.8))]
            if glyph == " ":
                continue
            color = mix(CANVAS, gradient(x / W), 0.25 + 0.7 * v if wave else 0.35)
            d.text((s(x - cw / 2), s(y - ch / 2)), glyph, font=mono, fill=color)

    # Arrowhead where the waveform reaches Applications.
    ax = APPS_X - 86
    d.line([(s(ax - 9), s(ICON_Y - 9)), (s(ax), s(ICON_Y)), (s(ax - 9), s(ICON_Y + 9))],
           fill=VIOLET, width=s(2.5), joint="curve")

    serif = ImageFont.truetype(f"{FONTS}/InstrumentSerif-Regular.ttf", s(34))
    serif_i = ImageFont.truetype(f"{FONTS}/InstrumentSerif-Italic.ttf", s(34))
    parts = [("Drag to ", serif, INK), ("Applications", serif_i, SIGNAL), (" to install", serif, INK)]
    total = sum(d.textlength(t, font=f) for t, f, _ in parts)
    x = (s(W) - total) / 2
    for text, font, color in parts:
        d.text((x, s(48)), text, font=font, fill=color)
        x += d.textlength(text, font=font)

    small = ImageFont.truetype(f"{FONTS}/FragmentMono-Regular.ttf", s(11))
    caption = "speak  →  text  ·  on-device by default"
    tw = d.textlength(caption, font=small)
    d.text(((s(W) - tw) / 2, s(H - 34)), caption, font=small, fill=GRAPHITE)
    return img


with tempfile.TemporaryDirectory() as tmp:
    one, two = f"{tmp}/bg.png", f"{tmp}/bg@2x.png"
    render(1).save(one, dpi=(72, 72))
    hi = render(2)
    hi.save(two, dpi=(144, 144))
    hi.save(f"{HERE}/background-preview.png")
    # Multi-resolution TIFF so Finder picks the sharp one on Retina displays.
    subprocess.run(["tiffutil", "-cathidpicheck", one, two, "-out", f"{HERE}/background.tiff"], check=True)
print("Wrote Scripts/dmg/background.tiff")
