#!/usr/bin/env python3
"""Generate src/resources/apfs_for_windows.ico (stacked AP/FS mark).

Mirrors renderMark() in src/manager/apfs_mount_manager.cpp so the executable,
installer, and Apps & Features icon match the tray icon. Run with -I:
    python -I scripts/generate-app-icon.py
Requires Pillow and the Segoe UI Bold font (Windows).
"""
import io
import os
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

SIZES = (16, 20, 24, 32, 40, 48, 64, 96, 128, 256)
ACCENT = (80, 176, 214, 255)
FILL = (20, 42, 58, 255)
FONT = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts", "segoeuib.ttf")
SUPERSAMPLE = 4


def render(size: int) -> Image.Image:
    big = size * SUPERSAMPLE
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    s = float(big)
    stroke = max(1.0 * SUPERSAMPLE, s / 32.0)
    inset = stroke / 2.0 + (0.0 if size <= 20 else s * 0.04)
    box = (inset, inset, s - inset, s - inset)
    draw.rounded_rectangle(box, radius=s * 0.14, fill=FILL, outline=ACCENT, width=round(stroke))
    mid = s / 2.0
    line_w = max(1.0 * SUPERSAMPLE, s / 42.0)
    draw.line((box[0] + s * 0.16, mid, box[2] - s * 0.16, mid), fill=ACCENT, width=round(line_w))
    font_px = max(6 * SUPERSAMPLE, int(s * (0.40 if size <= 24 else 0.31)))
    font = ImageFont.truetype(FONT, font_px)
    for text, top, bottom in (("AP", box[1], mid), ("FS", mid, box[3])):
        left, t, right, b = draw.textbbox((0, 0), text, font=font)
        w, h = right - left, b - t
        x = (s - w) / 2.0 - left
        y = top + ((bottom - top) - h) / 2.0 - t
        draw.text((x, y), text, font=font, fill=(255, 255, 255, 255))
    return img.resize((size, size), Image.LANCZOS)


def write_ico(path: str) -> None:
    blobs = []
    for size in SIZES:
        buf = io.BytesIO()
        render(size).save(buf, format="PNG", optimize=True)
        blobs.append((size, buf.getvalue()))
    header = struct.pack("<HHH", 0, 1, len(blobs))
    offset = 6 + 16 * len(blobs)
    entries = b""
    for size, data in blobs:
        dim = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", dim, dim, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
    with open(path, "wb") as handle:
        handle.write(header + entries + b"".join(d for _, d in blobs))


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "src", "resources", "apfs_for_windows.ico")
    write_ico(out)
    preview = os.path.join(root, "src", "resources", "apfs_for_windows_256.png")
    render(256).save(preview)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
