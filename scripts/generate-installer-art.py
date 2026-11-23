#!/usr/bin/env python3
"""Generate the WiX installer banner and dialog bitmaps.

Writes installer/assets/banner.bmp (493x58) and installer/assets/dialog.bmp
(493x312) in the product colors used by the tray icon. Run with -I:
    python -I scripts/generate-installer-art.py
Requires Pillow and Segoe UI fonts (Windows).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ACCENT = (80, 176, 214)
NAVY = (20, 42, 58)
WHITE = (255, 255, 255)
FONTS = os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "Fonts")


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(os.path.join(FONTS, name), size)


def mark(size: int) -> Image.Image:
    scale = 4
    big = size * scale
    img = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    s = float(big)
    stroke = max(scale, s / 32.0)
    inset = stroke / 2.0 + s * 0.04
    box = (inset, inset, s - inset, s - inset)
    draw.rounded_rectangle(box, radius=s * 0.14, fill=NAVY + (255,), outline=ACCENT + (255,),
                           width=round(stroke))
    mid = s / 2.0
    draw.line((box[0] + s * 0.16, mid, box[2] - s * 0.16, mid), fill=ACCENT + (255,),
              width=round(max(scale, s / 42.0)))
    f = font("segoeuib.ttf", int(s * 0.31))
    for text, top, bottom in (("AP", box[1], mid), ("FS", mid, box[3])):
        left, t, right, b = draw.textbbox((0, 0), text, font=f)
        draw.text(((s - (right - left)) / 2.0 - left, top + ((bottom - top) - (b - t)) / 2.0 - t),
                  text, font=f, fill=WHITE + (255,))
    return img.resize((size, size), Image.LANCZOS)


def banner(path: str) -> None:
    # WiX draws the page title over the left part of the banner; keep it white.
    img = Image.new("RGB", (493, 58), WHITE)
    draw = ImageDraw.Draw(img)
    draw.rectangle((0, 55, 493, 58), fill=ACCENT)
    icon = mark(44)
    img.paste(icon, (493 - 44 - 8, 6), icon)
    img.save(path, format="BMP")


def dialog(path: str) -> None:
    # WiX places text on the right 329 px of the welcome/exit dialogs.
    img = Image.new("RGB", (493, 312), WHITE)
    draw = ImageDraw.Draw(img)
    draw.rectangle((0, 0, 163, 312), fill=NAVY)
    draw.rectangle((160, 0, 163, 312), fill=ACCENT)
    icon = mark(96)
    img.paste(icon, ((164 - 96) // 2, 48), icon)
    title = font("segoeuib.ttf", 17)
    sub = font("segoeui.ttf", 12)
    for text, f, y, color in (("APFS for", title, 162, WHITE), ("Windows", title, 184, WHITE),
                              ("Native APFS volumes", sub, 222, ACCENT), ("in Explorer", sub, 238, ACCENT)):
        left, _, right, _ = draw.textbbox((0, 0), text, font=f)
        draw.text(((164 - (right - left)) / 2 - left, y), text, font=f, fill=color)
    img.save(path, format="BMP")


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "installer", "assets")
    os.makedirs(out, exist_ok=True)
    banner(os.path.join(out, "banner.bmp"))
    dialog(os.path.join(out, "dialog.bmp"))
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
