"""Generates the store cover images the portal asks for.

Composed from the game's own atlas rather than drawn separately, so the cover
promises exactly what the game delivers: the same creatures, the same palette,
the same pixel scale. Sprites are enlarged with nearest-neighbour because the
renderer draws them with filtering off — smoothing them here would advertise a
softness the game does not have.

    python3 tools/cover.py

Writes art/cover-landscape.png (1920x1080), art/cover-portrait.png (800x1200)
and art/cover-square.png (800x800).
"""

import json
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, "art")

BG = (5, 6, 13)
CYAN = (60, 224, 220)
GOLD = (255, 217, 94)
MENACE = (224, 24, 7)
TEXT = (216, 226, 236)
DIM = (122, 134, 153)

FONT_PATH = "/System/Library/Fonts/Menlo.ttc"


def font(size):
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except OSError:
        return ImageFont.load_default()


class Atlas:
    def __init__(self):
        with open(os.path.join(ROOT, "assets", "atlas.json")) as f:
            self.manifest = json.load(f)
        self.image = Image.open(os.path.join(ROOT, "assets", "atlas.png")).convert("RGBA")

    def sprite(self, name, scale):
        x, y, w, h = self.manifest["frames"][name]
        cut = self.image.crop((x, y, x + w, y + h))
        # Nearest, to match the renderer's FilterQuality.none.
        return cut.resize((int(w * scale), int(h * scale)), Image.NEAREST)


def lattice(draw, size, step, colour):
    """The backdrop's dot grid, at cover scale."""
    for y in range(0, size[1] + step, step):
        for x in range(0, size[0] + step, step):
            draw.rectangle([x, y, x + 2, y + 2], fill=colour)


def glow(layer, radius):
    return layer.filter(ImageFilter.GaussianBlur(radius))


def ring(draw, cx, cy, r, colour, width):
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=colour, width=width)


def compose(size, atlas, layout):
    w, h = size
    base = Image.new("RGB", size, BG)
    d = ImageDraw.Draw(base)
    lattice(d, size, layout["lattice"], (16, 22, 34))

    # Everything that glows goes on its own layer and is added, matching the
    # renderer's additive pass.
    lights = Image.new("RGB", size, (0, 0, 0))
    ld = ImageDraw.Draw(lights)

    px, py = layout["player"]
    aura = layout["aura"]
    ring(ld, px, py, aura, CYAN, layout["auraWidth"])
    ring(ld, px, py, int(aura * 0.62), CYAN, max(2, layout["auraWidth"] // 2))

    # Incoming fire, telegraphed from the two shooters.
    for (sx, sy), (tx, ty) in layout["telegraphs"]:
        ld.line([sx, sy, tx, ty], fill=MENACE, width=layout["auraWidth"])

    base = ImageChops.add(base, glow(lights, layout["bloom"]))

    # Enemies behind, player in front.
    for name, (x, y), scale in layout["enemies"]:
        s = atlas.sprite(name, scale)
        base.paste(s, (x - s.width // 2, y - s.height // 2), s)

    # The aura again, crisp, over the bodies. Bloom alone left it as a smudge,
    # and the aura is the clearest signal that the player has abilities at all.
    d = ImageDraw.Draw(base)
    ring(d, px, py, aura, CYAN, max(2, layout["auraWidth"] // 2))

    host = atlas.sprite("host_0", layout["hostScale"])
    base.paste(host, (px - host.width // 2, py - host.height // 2), host)

    # Orbiting shards, the game's most recognisable ability.
    for i in range(layout["orbits"]):
        a = math.tau * i / layout["orbits"] - 0.5
        ox = px + int(math.cos(a) * aura)
        oy = py + int(math.sin(a) * aura)
        s = atlas.sprite("orb_frost", layout["orbScale"])
        base.paste(s, (ox - s.width // 2, oy - s.height // 2), s)

    for name, (x, y), scale in layout["shots"]:
        s = atlas.sprite(name, scale)
        base.paste(s, (x - s.width // 2, y - s.height // 2), s)

    # A soft shade under the wordmark. Their first requirement is readable
    # content, and white letters over a bright creature are not that; a stroke
    # alone only outlines the problem.
    tx, ty = layout["title"]
    shade = Image.new("L", size, 0)
    sd = ImageDraw.Draw(shade)
    sw, sh = layout["shade"]
    sd.ellipse([tx - sw, ty - sh, tx + sw, ty + sh + layout["taglineGap"]],
               fill=210)
    shade = shade.filter(ImageFilter.GaussianBlur(min(sw, sh) * 0.45))
    base = Image.composite(Image.new("RGB", size, BG), base, shade)

    # Wordmark last, over everything.
    d = ImageDraw.Draw(base)
    title = font(layout["titleSize"])
    d.text((tx, ty), "SPLICE", font=title, fill=TEXT,
           anchor=layout["anchor"], stroke_width=layout["titleSize"] // 18,
           stroke_fill=BG)
    d.text((tx, ty + layout["taglineGap"]), layout["tagline"],
           font=font(layout["taglineSize"]), fill=GOLD, anchor=layout["anchor"],
           stroke_width=max(2, layout["taglineSize"] // 8), stroke_fill=BG)
    return base


def swarm(cx, cy, count, radius, spread, names, scale, seed=0):
    """An arc of enemies converging on a point.

    The game's threat is density, not any single creature, and a handful of
    large sprites scattered around reads as a cast list rather than a swarm.
    """
    out = []
    for i in range(count):
        # Deterministic jitter — the same cover every build.
        j = math.sin((i + seed) * 12.9898) * 43758.5453
        j -= math.floor(j)
        k = math.sin((i + seed) * 78.233) * 12345.6789
        k -= math.floor(k)
        a = spread[0] + (spread[1] - spread[0]) * (i / max(1, count - 1))
        a += (j - 0.5) * 0.16
        r = radius[0] + (radius[1] - radius[0]) * k
        name = names[i % len(names)]
        size = scale[0] + (scale[1] - scale[0]) * ((i * 7 % 5) / 4)
        out.append((name, (int(cx + math.cos(a) * r), int(cy + math.sin(a) * r)),
                    size))
    return out


def landscape(atlas):
    px, py = 470, 690
    return compose((1920, 1080), atlas, dict(
        lattice=96, bloom=22, player=(px, py), aura=232, auraWidth=7,
        hostScale=13, orbScale=7, orbits=5,
        enemies=swarm(px, py, 26, (430, 1180), (-1.15, 1.15),
                      ["crawler_1", "mote_0", "spiker_0", "weaver_3",
                       "mote_2", "crawler_3", "spiker_2"], (5.5, 9))
        + [("brute_2", (1130, 880), 12), ("elite_0", (1540, 470), 10),
           ("spitter_0", (1500, 830), 10), ("lancer_1", (1330, 200), 10)],
        telegraphs=[((1500, 830), (px + 130, py + 60)),
                    ((1330, 200), (px + 110, py - 90))],
        shots=[("fang", (1080, 700), 6), ("fang", (960, 430), 5),
               ("shard_frost", (760, 560), 7), ("orb_frost", (880, 800), 6)],
        title=(470, 210), titleSize=140, anchor="mm", shade=(430, 130),
        tagline="BREED YOUR ABILITIES", taglineSize=38, taglineGap=104,
    ))


def portrait(atlas):
    px, py = 400, 820
    return compose((800, 1200), atlas, dict(
        lattice=80, bloom=18, player=(px, py), aura=190, auraWidth=6,
        hostScale=11, orbScale=6, orbits=5,
        enemies=swarm(px, py, 22, (330, 620), (-2.9, 0.25),
                      ["crawler_1", "mote_0", "spiker_0", "weaver_3",
                       "mote_2", "crawler_3"], (5, 8), seed=3)
        + [("brute_2", (160, 1060), 9), ("elite_0", (620, 500), 8),
           ("spitter_0", (690, 990), 9), ("lancer_1", (120, 620), 9)],
        telegraphs=[((690, 990), (px + 90, py + 70)),
                    ((120, 620), (px - 80, py - 70))],
        shots=[("fang", (560, 940), 5), ("fang", (250, 690), 5),
               ("shard_frost", (520, 760), 6)],
        title=(400, 250), titleSize=92, anchor="mm", shade=(300, 90),
        tagline="BREED YOUR ABILITIES", taglineSize=25, taglineGap=70,
    ))


def square(atlas):
    px, py = 400, 540
    return compose((800, 800), atlas, dict(
        lattice=80, bloom=16, player=(px, py), aura=165, auraWidth=6,
        hostScale=10, orbScale=6, orbits=5,
        enemies=swarm(px, py, 18, (280, 470), (-2.85, 0.2),
                      ["crawler_1", "mote_0", "spiker_0", "weaver_3",
                       "mote_2"], (5, 7.5), seed=7)
        + [("brute_2", (165, 700), 8), ("elite_0", (640, 320), 7),
           ("spitter_0", (700, 640), 8)],
        telegraphs=[((700, 640), (px + 80, py + 50))],
        shots=[("fang", (560, 590), 5), ("shard_frost", (300, 400), 5)],
        title=(400, 140), titleSize=84, anchor="mm", shade=(280, 84),
        tagline="BREED YOUR ABILITIES", taglineSize=21, taglineGap=62,
    ))


def main():
    os.makedirs(ART, exist_ok=True)
    atlas = Atlas()
    for name, build in (("landscape", landscape), ("portrait", portrait),
                        ("square", square)):
        img = build(atlas)
        path = os.path.join(ART, f"cover-{name}.png")
        img.save(path)
        print(f"  {os.path.relpath(path, ROOT)}  {img.width}x{img.height}")


if __name__ == "__main__":
    main()
