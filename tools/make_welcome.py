#!/usr/bin/env python3
"""Welcome screen shown while the PS5 stage loads (bringup/tools/kms_linear.py puts it on screen, the crash-kexec keeps it scanned out).
Writes build/welcome.raw: 2560x1440, 32 bit XRGB little endian (bytes B G R 0xFF), pitch 10240 = what the DRM dumb buffer uses.
The top-left corner stays dark: stage 1 prints its text console there. kms_linear.py writes the 8 signature pixels afterwards.
Usage: make_welcome.py [out.raw] [out.png]"""
import math, sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 2560, 1440
ROOT = Path(__file__).resolve().parent.parent
out = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "build/welcome.raw"
png = Path(sys.argv[2]) if len(sys.argv) > 2 else None


def font(size, bold=False):
    for p in ("/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/SFNS.ttf", "/Library/Fonts/Arial.ttf",
              "/usr/share/fonts/TTF/DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(p, size, index=1 if bold and p.endswith(".ttc") else 0)
        except Exception:
            continue
    return ImageFont.load_default()


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


# background: deep blue at the top-left, magenta/violet sweeping to the bottom-right (the Monterey colours), drawn as a small image
# and scaled up (smooth and cheap)
small = Image.new("RGB", (256, 144))
px = small.load()
c0, c1, c2 = (8, 10, 40), (60, 30, 140), (200, 50, 140)
for y in range(144):
    for x in range(256):
        t = (x / 255 * 0.55 + y / 143 * 0.45)
        t = t ** 1.15
        px[x, y] = lerp(c0, c1, t * 2) if t < 0.5 else lerp(c1, c2, (t - 0.5) * 2)
img = small.resize((W, H), Image.BICUBIC)

# soft waves
wave = Image.new("RGB", (W, H), (0, 0, 0))
d = ImageDraw.Draw(wave)
for k, col in enumerate(((255, 90, 170), (120, 80, 255), (60, 160, 255))):
    pts = [(x, int(H * (0.62 + 0.07 * k) + 90 * math.sin(x / 330 + k * 1.7) + 40 * math.sin(x / 120 + k))) for x in range(0, W + 20, 20)]
    d.polygon(pts + [(W, H), (0, H)], fill=col)
    wave = wave.filter(ImageFilter.GaussianBlur(14))
    d = ImageDraw.Draw(wave)
img = Image.blend(img, Image.composite(wave, img, Image.new("L", (W, H), 255)), 0.22)

# keep the top-left dark for the stage-1 text console
mask = Image.new("L", (W, H), 0)
ImageDraw.Draw(mask).rectangle((0, 0, 1280, 560), fill=235)
img = Image.composite(Image.new("RGB", (W, H), (16, 16, 64)), img, mask.filter(ImageFilter.GaussianBlur(40)))

d = ImageDraw.Draw(img)
cx, cy = W // 2 + 260, H // 2


def centred(text, f, y, fill):
    w = d.textlength(text, font=f)
    d.text((cx - w / 2, y), text, font=f, fill=fill)


centred("macOS on PS5", font(190, True), cy - 210, (255, 255, 255))
centred("Bare-metal Hackintosh", font(78), cy + 20, (235, 225, 255))
centred("Monterey 12.7.6   ·   AMD Zen 2   ·   no virtual machine", font(50), cy + 135, (205, 195, 240))
centred("Starting up... pick Macintosh HD in the boot menu", font(44), H - 170, (255, 255, 255))
out.parent.mkdir(parents=True, exist_ok=True)
r, g, b = img.split()
raw = Image.merge("RGBA", (b, g, r, Image.new("L", (W, H), 255))).tobytes()
assert len(raw) == W * H * 4
out.write_bytes(raw)
if png:
    img.save(png)
print(f"wrote {out} ({len(raw)} bytes)")
