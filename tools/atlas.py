"""Pack every sprite into one texture atlas plus a JSON manifest.

Flutter draws the whole scene through Canvas.drawAtlas, which takes a single
ui.Image and per-sprite (Rect, RSTransform). One atlas therefore means one draw
call for all creatures, projectiles and particles, which is the difference
between 60fps and a slideshow once entity counts climb.
"""

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image, ImageDraw, ImageFilter

from creature import ARCHETYPES, PALETTES, hex2rgb, render_creature

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ART = os.path.join(ROOT, "art")
ASSETS = os.path.join(ROOT, "assets")

ATLAS_WIDTH = 512
PAD = 2  # transparent gutter, so bilinear sampling never bleeds between frames

SPECIES_PALETTE = {
    "mote": "cyan", "crawler": "acid", "spiker": "blood", "floater": "void",
    "brute": "amber", "weaver": "magenta", "elite": "bone", "host": "spirit",
}

# Damage types. Each one owns a colour so the player can read what is hitting
# what without a single word of text on screen.
PAYLOAD_PALETTE = {
    "kinetic": "bone",
    "burn": "amber",
    "frost": "cyan",
    "corrode": "acid",
    "shock": "volt",
    "bleed": "blood",
    "void": "void",
}

# Electric blue, only used by the shock payload.
PALETTES["volt"] = ["#0a1020", "#173a80", "#2f86dd", "#74d4ff", "#eafaff"]

VARIANTS_PER_ARCHETYPE = 4


def glow_dot(diameter, palette, hot=1.0):
    """A soft luminous ball: projectiles, sparks, XP motes."""
    ramp = [hex2rgb(c) for c in PALETTES[palette]]
    pad = max(3, diameter)
    dim = diameter + pad * 2
    img = Image.new("RGBA", (dim, dim), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = (dim - 1) / 2.0
    r = diameter / 2.0
    d.ellipse([c - r, c - r, c + r, c + r], fill=ramp[3] + (255,))
    if diameter >= 5:
        ri = r * 0.5
        d.ellipse([c - ri, c - ri, c + ri, c + ri], fill=ramp[4] + (255,))

    halo = img.filter(ImageFilter.GaussianBlur(diameter * 0.55))
    halo.putalpha(halo.getchannel("A").point(lambda v: min(255, int(v * 0.75 * hot))))
    return Image.alpha_composite(halo, img)


def bolt(length, thickness, palette):
    """A stretched projectile that points along +x, so rotation is trivial."""
    ramp = [hex2rgb(c) for c in PALETTES[palette]]
    pad = 5
    w, h = length + pad * 2, thickness + pad * 2
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cy = (h - 1) / 2.0
    d.rounded_rectangle([pad, cy - thickness / 2, pad + length, cy + thickness / 2],
                        radius=thickness / 2, fill=ramp[3] + (255,))
    if thickness >= 3:
        d.rounded_rectangle([pad + 1, cy - thickness / 4 - 0.5, pad + length - 1,
                             cy + thickness / 4 + 0.5],
                            radius=thickness / 4, fill=ramp[4] + (255,))
    halo = img.filter(ImageFilter.GaussianBlur(2.4))
    halo.putalpha(halo.getchannel("A").point(lambda v: min(255, int(v * 0.7))))
    return Image.alpha_composite(halo, img)


def ring(diameter, thickness, palette):
    """Shockwaves, aura boundaries, telegraph circles. Scaled at runtime."""
    ramp = [hex2rgb(c) for c in PALETTES[palette]]
    pad = 6
    dim = diameter + pad * 2
    img = Image.new("RGBA", (dim, dim), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = (dim - 1) / 2.0
    r = diameter / 2.0
    d.ellipse([c - r, c - r, c + r, c + r], outline=ramp[3] + (255,), width=thickness)
    halo = img.filter(ImageFilter.GaussianBlur(2.8))
    halo.putalpha(halo.getchannel("A").point(lambda v: min(255, int(v * 0.8))))
    return Image.alpha_composite(halo, img)


def shard(size, palette):
    """Angular fragment for death bursts — reads differently from round sparks."""
    ramp = [hex2rgb(c) for c in PALETTES[palette]]
    pad = 4
    dim = size + pad * 2
    img = Image.new("RGBA", (dim, dim), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    c = (dim - 1) / 2.0
    r = size / 2.0
    pts = [(c + r, c), (c, c + r * 0.55), (c - r, c), (c, c - r * 0.55)]
    d.polygon(pts, fill=ramp[3] + (255,))
    halo = img.filter(ImageFilter.GaussianBlur(1.8))
    halo.putalpha(halo.getchannel("A").point(lambda v: min(255, int(v * 0.7))))
    return Image.alpha_composite(halo, img)


def build_sprites():
    """Return an ordered {name: RGBA image} of everything the game draws."""
    out = {}

    # Enemy and player bodies. Several seeds per archetype so a swarm of the
    # same species still looks like individuals rather than clones.
    for name in ARCHETYPES:
        for i in range(VARIANTS_PER_ARCHETYPE):
            out[f"{name}_{i}"] = render_creature(name, SPECIES_PALETTE[name], seed=i * 7 + 1)

    # Per-payload effect sets.
    for pay, pal in PAYLOAD_PALETTE.items():
        out[f"spark_{pay}"] = glow_dot(4, pal)
        out[f"orb_{pay}"] = glow_dot(7, pal)
        out[f"burst_{pay}"] = glow_dot(13, pal)
        out[f"bolt_{pay}"] = bolt(11, 3, pal)
        out[f"shard_{pay}"] = shard(7, pal)
        out[f"ring_{pay}"] = ring(30, 2, pal)

    # Pickups and generic effects.
    out["xp_small"] = glow_dot(5, "volt")
    out["xp_large"] = glow_dot(8, "volt")
    out["heal"] = glow_dot(8, "acid")
    out["ring_white"] = ring(30, 2, "bone")
    out["dot_white"] = glow_dot(3, "bone")
    return out


def pack(sprites, width=ATLAS_WIDTH):
    """Shelf packer. Tallest-first keeps the wasted strip height small."""
    order = sorted(sprites.items(), key=lambda kv: -kv[1].height)
    frames, x, y, shelf_h = {}, PAD, PAD, 0
    for name, img in order:
        if x + img.width + PAD > width:
            x, y, shelf_h = PAD, y + shelf_h + PAD, 0
        frames[name] = dict(x=x, y=y, w=img.width, h=img.height)
        x += img.width + PAD
        shelf_h = max(shelf_h, img.height)
    height = y + shelf_h + PAD

    # Power-of-two height is friendlier to older mobile GPUs.
    height = 1 << (height - 1).bit_length()
    atlas = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    for name, f in frames.items():
        atlas.alpha_composite(sprites[name], (f["x"], f["y"]))
    return atlas, frames, height


def main():
    os.makedirs(ART, exist_ok=True)
    os.makedirs(ASSETS, exist_ok=True)

    sprites = build_sprites()
    atlas, frames, height = pack(sprites)

    manifest = {
        "image": "atlas.png",
        "size": [ATLAS_WIDTH, height],
        # Pivot is the sprite centre; every frame is drawn centred on its entity.
        "frames": {n: [f["x"], f["y"], f["w"], f["h"]] for n, f in sorted(frames.items())},
        "payloadPalette": PAYLOAD_PALETTE,
        "speciesPalette": SPECIES_PALETTE,
        # Ramp stops travel with the atlas so UI and particles can tint to match.
        "palettes": {k: v for k, v in PALETTES.items()},
        "variants": VARIANTS_PER_ARCHETYPE,
    }

    for target in (ART, ASSETS):
        atlas.save(os.path.join(target, "atlas.png"))
        with open(os.path.join(target, "atlas.json"), "w") as fh:
            json.dump(manifest, fh, indent=1, sort_keys=True)

    used = sum(f["w"] * f["h"] for f in frames.values())
    print(f"{len(frames)} frames -> {ATLAS_WIDTH}x{height} "
          f"({used / (ATLAS_WIDTH * height) * 100:.0f}% packed, "
          f"{os.path.getsize(os.path.join(ART, 'atlas.png')) / 1024:.0f} KB)")


if __name__ == "__main__":
    main()
