"""Turn a generated square render into a macOS app icon (.icns + the sizes Finder wants).

macOS icons are not a full-bleed square: the artwork sits in a rounded "squircle" that
occupies 824 of the 1024 canvas (100 px of margin on each side), with a corner radius of
about 184. A raw render pasted in edge to edge looks oversized next to every system icon.

Usage: make_icon.py <render.png> <outdir>
"""
import os
import subprocess
import sys

from PIL import Image, ImageDraw

CANVAS = 1024
BODY = 824                      # Apple's icon body inside the 1024 canvas
RADIUS = 184                    # ... and its corner radius
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def mask(oversample=4):
    """The squircle as an 8-bit mask, drawn large and shrunk for smooth edges."""
    big = Image.new("L", (CANVAS * oversample, CANVAS * oversample), 0)
    margin = (CANVAS - BODY) // 2 * oversample
    draw = ImageDraw.Draw(big)
    draw.rounded_rectangle(
        [margin, margin, CANVAS * oversample - margin - 1, CANVAS * oversample - margin - 1],
        radius=RADIUS * oversample, fill=255)
    return big.resize((CANVAS, CANVAS), Image.LANCZOS)


def main():
    source, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)

    art = Image.open(source).convert("RGBA")
    if art.size != (CANVAS, CANVAS):
        # Centre-crop to square, then scale, so a non-square render is not stretched.
        side = min(art.size)
        left, top = (art.width - side) // 2, (art.height - side) // 2
        art = art.crop((left, top, left + side, top + side)).resize((CANVAS, CANVAS), Image.LANCZOS)

    icon = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    icon.paste(art, (0, 0), mask())
    icon.save(os.path.join(outdir, "icon-1024.png"))

    iconset = os.path.join(outdir, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for size, scale in SIZES:
        px = size * scale
        name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))

    icns = os.path.join(outdir, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print("wrote", icns, os.path.getsize(icns), "bytes")
    print("wrote", os.path.join(outdir, "icon-1024.png"))


if __name__ == "__main__":
    main()
