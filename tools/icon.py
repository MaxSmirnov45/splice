"""Generate the app icon.

The host creature at icon scale, with an orbit ring behind it — the game's
premise in one mark. Pixels are upscaled nearest-neighbour so the pixel-art
identity survives, then a smooth glow is added at full resolution rather than
upscaled from the sprite's baked one.

Outputs:
  art/icon.png            1024 square, opaque   (iOS + legacy Android)
  art/icon_foreground.png 1024 square, alpha    (Android adaptive foreground)
"""

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image, ImageDraw, ImageFilter

from creature import PALETTES, hex2rgb, render_creature

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, "art")

SIZE = 1024
BG_TOP = (10, 13, 26)
BG_BOTTOM = (3, 4, 9)


def _background():
    """Vertical gradient with a cyan bloom behind the subject."""
    img = Image.new("RGB", (SIZE, SIZE), BG_BOTTOM)
    d = ImageDraw.Draw(img)
    for y in range(SIZE):
        t = y / (SIZE - 1)
        d.line([(0, y), (SIZE, y)],
               fill=tuple(int(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)))

    bloom = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bd = ImageDraw.Draw(bloom)
    r = SIZE * 0.30
    bd.ellipse([SIZE / 2 - r, SIZE / 2 - r, SIZE / 2 + r, SIZE / 2 + r],
               fill=(30, 120, 150, 120))
    bloom = bloom.filter(ImageFilter.GaussianBlur(SIZE * 0.13))
    return Image.alpha_composite(img.convert("RGBA"), bloom)


def _orbit_ring(layer, ramp):
    """The thin ring and three satellites that read as 'orbit' at any size."""
    d = ImageDraw.Draw(layer)
    cx = cy = SIZE / 2
    radius = SIZE * 0.335

    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius],
              outline=ramp[2] + (170,), width=9)

    for i in range(3):
        a = math.radians(-90 + i * 120)
        px, py = cx + math.cos(a) * radius, cy + math.sin(a) * radius
        rr = SIZE * 0.031
        d.ellipse([px - rr, py - rr, px + rr, py + rr], fill=ramp[4] + (255,))
        rr2 = rr * 1.9
        d.ellipse([px - rr2, py - rr2, px + rr2, py + rr2],
                  outline=ramp[3] + (110,), width=5)


def _subject(scale_to):
    """The host creature, upscaled with hard pixel edges."""
    sprite = render_creature("host", "spirit", seed=1, pad=1, glow=False)
    factor = max(1, int(scale_to / sprite.width))
    return sprite.resize((sprite.width * factor, sprite.height * factor), Image.NEAREST)


def _glow_from(layer, blur, strength):
    """A soft halo generated from a layer's own bright pixels."""
    halo = layer.filter(ImageFilter.GaussianBlur(blur))
    halo.putalpha(halo.getchannel("A").point(lambda v: min(255, int(v * strength))))
    return halo


def build_foreground():
    """Transparent-background artwork, used for the Android adaptive icon.

    Android crops adaptive icons to a circle on many launchers and applies
    parallax, so the subject is kept inside the safe centre ~66%.
    """
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    ramp = [hex2rgb(c) for c in PALETTES["spirit"]]
    cyan = [hex2rgb(c) for c in PALETTES["cyan"]]

    _orbit_ring(layer, cyan)

    subject = _subject(int(SIZE * 0.40))
    layer.alpha_composite(subject,
                          ((SIZE - subject.width) // 2, (SIZE - subject.height) // 2))

    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    for blur, strength in ((46, 0.75), (14, 0.85)):
        out = Image.alpha_composite(out, _glow_from(layer, blur, strength))
    return Image.alpha_composite(out, layer), ramp


def main():
    os.makedirs(ART, exist_ok=True)

    foreground, _ = build_foreground()
    foreground.save(os.path.join(ART, "icon_foreground.png"))

    # iOS rejects alpha channels in the marketing icon, so flatten onto the
    # gradient rather than shipping transparency.
    full = Image.alpha_composite(_background(), foreground).convert("RGB")
    full.save(os.path.join(ART, "icon.png"))

    print(f"wrote icon.png and icon_foreground.png at {SIZE}x{SIZE}")


if __name__ == "__main__":
    main()
