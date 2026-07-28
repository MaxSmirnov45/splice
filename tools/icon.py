"""Generates the game's icon at every size the platforms want.

Drawn rather than drawn-over: the mark is built from the same vocabulary as
the in-game sigils — a dark field, glowing strands, a hot nucleus — so the
icon and the game read as the same object.

The subject is a sigil — the same mark the game stamps on every ability, so
the icon is not a picture *of* the game but a piece of it. A ring of rider
ticks, and inside it two strands, one cyan and one gold, curling into each
other around a single hot nucleus: two parents, one child.

Circular because it survives being 16 pixels tall. At that size it collapses
to a glowing ring with a bright centre, which is still unmistakably this game
and not a generic arrow or letter.

Glow is additive, matching the renderer's own BlendMode.plus. Compositing it
with alpha instead turns a white core into a grey disc, because white at low
opacity over a near-black field is simply grey.

    python3 tools/icon.py
"""

import math
import os
import re

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WEB = os.path.join(ROOT, "web")

# Straight from the game's palette. BG is Skin.bg; the strands are the two
# ramps the player already reads as theirs — frost cyan and the host's gold.
BG = (5, 6, 13)
CYAN = (60, 224, 220)
GOLD = (255, 217, 94)
CORE = (255, 251, 232)
# The ring is deliberately desaturated. Drawn in cyan it competed with the
# cyan strand, and the mark stopped reading as a pair of colours.
RING = (96, 116, 140)

SS = 4  # supersample; these strands are thin and alias badly without it


def _paint(layer, geom, scale):
    """Draws the mark onto an RGB layer at the given brightness."""
    d = ImageDraw.Draw(layer)

    def dim(colour):
        return tuple(int(v * scale) for v in colour)

    c, ring_r, ring_w, ticks, tick_len, tick_w, arcs, arc_w, core_r = geom

    # The generation ring an in-game sigil draws around a high-lineage ability.
    d.ellipse([c[0] - ring_r, c[1] - ring_r, c[0] + ring_r, c[1] + ring_r],
              outline=dim(RING), width=ring_w)

    # Rider ticks around the rim.
    for i in range(ticks):
        a = math.tau * i / ticks - math.pi / 2
        ca, sa = math.cos(a), math.sin(a)
        d.line([(c[0] + ca * (ring_r + tick_len * 0.35),
                 c[1] + sa * (ring_r + tick_len * 0.35)),
                (c[0] + ca * (ring_r + tick_len),
                 c[1] + sa * (ring_r + tick_len))],
               fill=dim(GOLD), width=tick_w)

    # The two strands, each curling half way round the nucleus.
    for pts, colour in arcs:
        d.line(pts, fill=dim(colour), width=arc_w, joint="curve")
        # Rounded at both ends. Flat caps left the strands looking snapped off
        # where they cross the ring.
        for x, y in (pts[0], pts[-1]):
            r = arc_w * 0.5
            d.ellipse([x - r, y - r, x + r, y + r], fill=dim(colour))

    d.ellipse([c[0] - core_r, c[1] - core_r, c[0] + core_r, c[1] + core_r],
              fill=dim(CORE))


def _spiral(c, r0, r1, a0, a1, steps=48):
    """A strand winding inward from (r0, a0) to (r1, a1)."""
    out = []
    for i in range(steps + 1):
        t = i / steps
        a = a0 + (a1 - a0) * t
        r = r0 + (r1 - r0) * t
        out.append((c[0] + math.cos(a) * r, c[1] + math.sin(a) * r))
    return out


def render(size, maskable=False):
    s = size * SS

    # Full-bleed and opaque throughout; the rounded corners are cut at the very
    # end. Adding glow to a canvas that is already transparent outside the
    # corners would light up the transparency too.
    base = Image.new("RGB", (s, s), BG)

    c = (s / 2, s / 2)
    # Maskable icons get cropped to whatever shape the launcher fancies, so
    # everything has to sit well inside the safe zone.
    outer = s * (0.30 if maskable else 0.375)
    arc_w = max(1, int(s * 0.075))

    # Point-symmetric, so the two strands read as one gesture rather than two
    # things that happen to be next to each other.
    arcs = [
        (_spiral(c, outer * 0.86, arc_w * 1.35, math.pi * 0.5, math.pi * 1.35),
         CYAN),
        (_spiral(c, outer * 0.86, arc_w * 1.35, math.pi * 1.5, math.pi * 2.35),
         GOLD),
    ]

    geom = (
        c,
        outer,
        max(1, int(s * 0.020)),        # ring width
        12,                            # rider ticks
        s * 0.052,                     # tick length
        max(1, int(s * 0.024)),        # tick width
        arcs,
        arc_w,
        arc_w * 0.78,                  # nucleus
    )

    # Two additive glow passes: a wide soft bloom and a tight bright one.
    for blur, scale in ((s * 0.055, 0.5), (s * 0.016, 0.8)):
        glow = Image.new("RGB", (s, s), (0, 0, 0))
        _paint(glow, geom, scale)
        base = ImageChops.add(base, glow.filter(ImageFilter.GaussianBlur(blur)))

    _paint(base, geom, 1.0)

    out = base.convert("RGBA")
    if not maskable:
        mask = Image.new("L", (s, s), 0)
        ImageDraw.Draw(mask).rounded_rectangle(
            [0, 0, s - 1, s - 1], radius=s * 0.22, fill=255)
        out.putalpha(mask)
    return out.resize((size, size), Image.LANCZOS)


def _native(paths_by_size, label):
    """Writes the icon at each size a native platform asks for."""
    for path, size in sorted(paths_by_size.items(), key=lambda kv: kv[1]):
        if not os.path.isdir(os.path.dirname(path)):
            continue
        # Native launcher icons are composited on the platform's own
        # background and must not carry rounded corners of their own — iOS
        # masks them and would round an already-rounded shape.
        render(size, maskable=True).save(path)
    print(f"  {label}: {len(paths_by_size)} sizes")


def main():
    os.makedirs(os.path.join(WEB, "icons"), exist_ok=True)
    outputs = {
        os.path.join(WEB, "favicon.png"): (64, False),
        os.path.join(WEB, "icons", "Icon-192.png"): (192, False),
        os.path.join(WEB, "icons", "Icon-512.png"): (512, False),
        os.path.join(WEB, "icons", "Icon-maskable-192.png"): (192, True),
        os.path.join(WEB, "icons", "Icon-maskable-512.png"): (512, True),
    }
    for path, (size, maskable) in outputs.items():
        render(size, maskable).save(path)
        print(f"  {os.path.relpath(path, ROOT)}  {size}px"
              f"{'  maskable' if maskable else ''}")

    # iOS. Sizes are fixed by Contents.json, which ships with the project.
    ios_dir = os.path.join(ROOT, "ios", "Runner", "Assets.xcassets",
                           "AppIcon.appiconset")
    ios = {}
    if os.path.isdir(ios_dir):
        for name in os.listdir(ios_dir):
            m = re.match(r"Icon-App-(\d+(?:\.\d+)?)x\1@(\d)x\.png", name)
            if m:
                ios[os.path.join(ios_dir, name)] = round(
                    float(m.group(1)) * int(m.group(2)))
        _native(ios, "ios")

    # Android launcher icons, by density bucket.
    android = {}
    for bucket, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96),
                       ("xxhdpi", 144), ("xxxhdpi", 192)):
        d = os.path.join(ROOT, "android", "app", "src", "main", "res",
                         f"mipmap-{bucket}")
        android[os.path.join(d, "ic_launcher.png")] = px
    _native(android, "android")

    # A large master, for store listings and portal thumbnails.
    master = os.path.join(ROOT, "art", "icon-1024.png")
    os.makedirs(os.path.dirname(master), exist_ok=True)
    render(1024).save(master)
    print(f"  {os.path.relpath(master, ROOT)}  1024px")


if __name__ == "__main__":
    main()
