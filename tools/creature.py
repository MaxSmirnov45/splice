"""Procedural creature sprite generator for SPLICE.

Bodies come from a mirrored Wyvill-kernel metaball field. The kernel has finite
support, so blobs merge smoothly and round off instead of saturating into the
flat-topped plateau a 1/r^2 falloff produces.

Shading is directional rather than concentric: for every body pixel we measure
the distance to the surface *toward* the light (up-left) and *away* from it.
Near the lit surface reads as rim, near the unlit surface reads as shadow, and
everything between is mid-tone. That is what gives the blobs volume.

A bright nucleus plus two blurred bloom passes are composited underneath, so
the bioluminescence is baked and the runtime never pays for a blur.

Everything is seeded: a given (archetype, palette, seed) always renders the
same creature. Ability sigils later key off genome hashes the same way.
"""

import math
import zlib
from random import Random

from PIL import Image, ImageDraw, ImageFilter

# Five stops, dark -> bright. 0 outline, 1 shadow, 2 mid, 3 rim, 4 nucleus.
PALETTES = {
    "cyan":    ["#03101a", "#0a3a4d", "#1682a0", "#3ce0dc", "#c8fffa"],
    "magenta": ["#170420", "#4d1050", "#a02186", "#f761b8", "#ffd6ef"],
    "acid":    ["#091405", "#27500f", "#68ac1c", "#bcf246", "#f0ffbe"],
    "amber":   ["#1c0c03", "#61290a", "#c26a12", "#ffb03c", "#ffe9bc"],
    "void":    ["#0a0718", "#2d1c64", "#623cbb", "#a37cff", "#e7dcff"],
    "blood":   ["#160306", "#571017", "#ab2331", "#f65a5a", "#ffcbc5"],
    "bone":    ["#131116", "#403c46", "#837c8e", "#cac3d2", "#f7f4fa"],
    # Reserved for the player. Warm, so the host never reads as swarm.
    "spirit":  ["#1a1206", "#5e4410", "#b8901f", "#ffd95e", "#fffbe8"],
    # Reserved for enemy ranged attacks and the creatures that make them.
    # A searing red-white owned by nothing the player can fire, so anything
    # this colour on screen is unambiguously incoming.
    "menace":  ["#200000", "#7a0400", "#e01807", "#ff5a2e", "#fff0d8"],
}

BG = (5, 6, 13, 255)

# Light arrives from the upper left, consistently, for every sprite in the game.
LIGHT = (-1, -1)


def hex2rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


# --- archetypes -------------------------------------------------------------
# size      : native pixel dimension of the body box
# balls     : metaball count (more = lumpier silhouette)
# spread    : how far from centre metaballs may sit, as a fraction of size
# radius    : (min, max) kernel radius as a fraction of size
# elong     : >1 stretches vertically, <1 squashes into a disc
# limbs     : (count, length, width) appendages radiating from the body
# limb_arc  : (start, end) angle window in degrees, 0 = right, 90 = down
# eyes      : number of glowing ocelli
# cut       : field cutoff; lower = fatter body
# nucleus   : radius of the bright core, as a fraction of size (0 = none)

ARCHETYPES = {
    # Basic swarm fodder. Tiny and fast; in a crowd it reads as a bright mote.
    "mote": dict(size=13, balls=2, spread=0.08, radius=(0.46, 0.56), elong=1.0,
                 limbs=(0, 0, 0), limb_arc=(0, 0), eyes=1, cut=0.13, nucleus=0.16),
    # Ground-hugging chaser with visible legs.
    "crawler": dict(size=19, balls=3, spread=0.16, radius=(0.34, 0.46), elong=0.86,
                    limbs=(6, 4.0, 2), limb_arc=(20, 160), eyes=2, cut=0.15, nucleus=0.13),
    # Aggressive melee shape, all silhouette spikes.
    "spiker": dict(size=21, balls=3, spread=0.18, radius=(0.32, 0.44), elong=1.0,
                   limbs=(8, 5.5, 2), limb_arc=(0, 360), eyes=1, cut=0.16, nucleus=0.14),
    # Drifting ranged attacker. Jellyfish read: dome plus trailing tendrils.
    "floater": dict(size=21, balls=3, spread=0.13, radius=(0.38, 0.50), elong=0.78,
                    limbs=(5, 7.5, 1), limb_arc=(58, 122), eyes=2, cut=0.14, nucleus=0.15),
    # Slow tank. Wide, heavy, low to the ground.
    "brute": dict(size=28, balls=5, spread=0.27, radius=(0.30, 0.42), elong=0.82,
                  limbs=(6, 6.0, 3), limb_arc=(25, 155), eyes=2, cut=0.16, nucleus=0.09),
    # Tall, thin and unsettling, with long limbs.
    "weaver": dict(size=25, balls=4, spread=0.22, radius=(0.26, 0.38), elong=1.55,
                   limbs=(6, 8.0, 2), limb_arc=(0, 360), eyes=3, cut=0.15, nucleus=0.10),
    # Wave boss. Big, horned, multi-eyed.
    "elite": dict(size=35, balls=5, spread=0.22, radius=(0.30, 0.44), elong=1.02,
                  limbs=(8, 7.5, 3), limb_arc=(0, 360), eyes=4, cut=0.14, nucleus=0.12),
    # Ranged. A bloated sac on stubby legs — reads as "carrying something",
    # and its bulk explains why it stops to fire instead of closing.
    "spitter": dict(size=22, balls=3, spread=0.11, radius=(0.42, 0.54), elong=0.88,
                    limbs=(4, 3.5, 3), limb_arc=(30, 150), eyes=1, cut=0.12, nucleus=0.24),
    # Ranged heavy. Long-bodied and horned, firing a fan from a distance.
    "lancer": dict(size=27, balls=4, spread=0.20, radius=(0.28, 0.40), elong=1.42,
                   limbs=(4, 9.0, 2), limb_arc=(300, 420), eyes=3, cut=0.14, nucleus=0.20),
    # The player host. Compact and symmetrical, deliberately calmer than the swarm.
    "host": dict(size=19, balls=3, spread=0.10, radius=(0.38, 0.50), elong=1.08,
                 limbs=(4, 3.5, 2), limb_arc=(35, 145), eyes=2, cut=0.14, nucleus=0.20),
}


def _metaball_field(rng, size, cfg):
    """size x size float field, mirrored about the vertical axis.

    Wyvill kernel: (1 - d^2/R^2)^3 inside R, zero outside. Finite support keeps
    blobs round; an unbounded falloff would sum into a boxy plateau.
    """
    cx = (size - 1) / 2.0
    cy = (size - 1) / 2.0
    elong = cfg["elong"]
    rmin, rmax = cfg["radius"]

    # First ball sits on the centre line so the creature always has a trunk.
    balls = [(cx, cy + rng.uniform(-0.08, 0.08) * size, rng.uniform(rmin, rmax) * size)]
    for _ in range(cfg["balls"] - 1):
        ang = rng.uniform(0, math.tau)
        dist = rng.uniform(0.03, cfg["spread"]) * size
        # abs() keeps generated balls on the right half; the field mirrors them.
        bx = cx + abs(math.cos(ang)) * dist
        by = cy + math.sin(ang) * dist * elong
        br = rng.uniform(rmin * 0.7, rmax) * size
        balls.append((bx, by, br))

    field = [[0.0] * size for _ in range(size)]
    for y in range(size):
        for x in range(size):
            total = 0.0
            for bx, by, br in balls:
                r2 = br * br
                dy = (y - by) / elong
                for px in (x, size - 1 - x):  # mirrored pair
                    dx = px - bx
                    d2 = dx * dx + dy * dy
                    if d2 < r2:
                        q = 1.0 - d2 / r2
                        total += q * q * q
            field[y][x] = total
    return field


def _dilate(mask):
    h, w = len(mask), len(mask[0])
    out = [[False] * w for _ in range(h)]
    for y in range(h):
        for x in range(w):
            if not mask[y][x]:
                continue
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if 0 <= ny < h and 0 <= nx < w:
                        out[ny][nx] = True
    return out


def _surface_distance(solid, dx, dy):
    """For each body pixel, steps along (dx, dy) before leaving the body.

    Computed by DP in the direction opposite to the walk, so it is O(pixels).
    """
    h, w = len(solid), len(solid[0])
    out = [[0] * w for _ in range(h)]
    ys = range(h) if dy < 0 else range(h - 1, -1, -1)
    xs = range(w) if dx < 0 else range(w - 1, -1, -1)
    for y in ys:
        for x in xs:
            if not solid[y][x]:
                continue
            ny, nx = y + dy, x + dx
            if not (0 <= ny < h and 0 <= nx < w) or not solid[ny][nx]:
                out[y][x] = 1
            else:
                out[y][x] = out[ny][nx] + 1
    return out


def _limb_points(rng, size, body, cfg, pad):
    """Appendages radiating from the body, mirrored left/right.

    Returned in padded image space so the caller can fold them into the mask
    before shading; that way limbs receive the same directional light.
    """
    count, length, width = cfg["limbs"]
    if count <= 0:
        return []
    a0, a1 = cfg["limb_arc"]
    cx = cy = (size - 1) / 2.0
    points = []
    half = max(1, count // 2)

    for i in range(half):
        ang = math.radians(a0 + (a1 - a0) * ((i + rng.uniform(0.2, 0.8)) / half))
        dx, dy = math.cos(ang), math.sin(ang)

        # Walk out from the centre to find the body surface along this ray.
        surface, t = 0.0, 0.0
        while t < size:
            sx, sy = int(round(cx + dx * t)), int(round(cy + dy * t))
            if 0 <= sx < size and 0 <= sy < size and body[sy][sx]:
                surface = t
            t += 0.5
        if surface <= 0:
            continue

        seg = length * rng.uniform(0.75, 1.2)
        steps = max(3, int(seg * 2))
        curve = rng.uniform(-0.55, 0.55)  # bend, so limbs read organic not spoke-like
        for s in range(steps + 1):
            f = s / steps
            a = ang + curve * f * f
            t = surface - 1.0 + seg * f
            px, py = cx + math.cos(a) * t, cy + math.sin(a) * t
            w = max(1, int(round(width * (1.0 - 0.7 * f))))  # taper to the tip
            for oy in range(-(w // 2), w - w // 2):
                for ox in range(-(w // 2), w - w // 2):
                    ix, iy = int(round(px)) + ox, int(round(py)) + oy
                    points.append((ix + pad, iy + pad))
                    points.append((size - 1 - ix + pad, iy + pad))
    return points


def render_creature(archetype="crawler", palette="cyan", seed=0, pad=10, glow=True):
    """Render one creature to an RGBA image with baked glow.

    Set glow=False to get the crisp pixels only. The icon pipeline needs that:
    it upscales with nearest-neighbour, and a pre-baked soft glow would come
    out as visible stair-stepping at 1024px.
    """
    cfg = ARCHETYPES[archetype]
    # crc32 rather than hash(): Python randomises string hashing per process,
    # which would make sprites differ between runs.
    rng = Random((zlib.crc32(archetype.encode()) ^ (seed * 2654435761)) & 0x7FFFFFFF)
    size = cfg["size"]
    ramp = [hex2rgb(c) for c in PALETTES[palette]]
    dim = size + pad * 2

    field = _metaball_field(rng, size, cfg)
    body = [[v >= cfg["cut"] for v in row] for row in field]

    # Promote the body into padded image space, then fold in the limbs so they
    # are shaded as part of the same solid.
    solid = [[False] * dim for _ in range(dim)]
    for y in range(size):
        for x in range(size):
            if body[y][x]:
                solid[y + pad][x + pad] = True
    for px, py in _limb_points(rng, size, body, cfg, pad):
        if 0 <= px < dim and 0 <= py < dim:
            solid[py][px] = True

    lx, ly = LIGHT
    lit = _surface_distance(solid, lx, ly)        # steps to the surface, toward light
    shade = _surface_distance(solid, -lx, -ly)    # steps to the surface, away from light
    grown = _dilate(solid)

    img = Image.new("RGBA", (dim, dim), (0, 0, 0, 0))
    px = img.load()
    for y in range(dim):
        for x in range(dim):
            if not solid[y][x]:
                if grown[y][x]:
                    px[x, y] = ramp[0] + (255,)
                continue
            if lit[y][x] <= 1:
                tone = ramp[3]      # rim facing the light
            elif shade[y][x] <= 1:
                tone = ramp[1]      # terminator edge in shadow
            elif lit[y][x] <= 3:
                tone = ramp[2]
            elif shade[y][x] <= 3:
                tone = ramp[1]
            else:
                tone = ramp[2]      # mid-tone interior
            px[x, y] = tone + (255,)

    _draw_nucleus(img, dim, cfg, ramp, solid)
    out = _apply_glow(img, ramp) if glow else img
    # Eyes go on after the bloom so they stay crisp instead of being washed out.
    _draw_eyes(out, rng, dim, cfg, ramp, solid)
    return out


def _draw_nucleus(img, dim, cfg, ramp, solid):
    """A bright organelle at the centre of mass. This is what makes it glow."""
    r = cfg["nucleus"] * cfg["size"]
    if r <= 0:
        return
    c = (dim - 1) / 2.0
    d = ImageDraw.Draw(img)
    d.ellipse([c - r, c - r * 0.9, c + r, c + r * 0.9], fill=ramp[4] + (255,))
    # Ring the nucleus in mid-tone so it doesn't bleed straight into the shell.
    d.ellipse([c - r, c - r * 0.9, c + r, c + r * 0.9], outline=ramp[3] + (255,))


def _draw_eyes(img, rng, dim, cfg, ramp, solid):
    """Ocelli, mirrored in pairs, in the upper body where a face reads."""
    n = cfg["eyes"]
    if n <= 0:
        return
    d = ImageDraw.Draw(img)
    cx = (dim - 1) / 2.0
    band = int(dim * rng.uniform(0.30, 0.38))
    pairs = (n + 1) // 2
    for i in range(pairs):
        off = (i + 1) * rng.uniform(1.7, 2.9)
        for sx in ((-1, 1) if n > 1 else (0,)):
            ex, ey = int(round(cx + off * sx)), band + int(i * 1.6)
            if not (0 <= ex < dim and 0 <= ey < dim) or not solid[ey][ex]:
                continue
            # Dark socket first, bright pupil on top: reads at small sizes.
            d.ellipse([ex - 1, ey - 1, ex + 1, ey + 1], fill=ramp[0] + (255,))
            d.point((ex, ey), fill=ramp[4] + (255,))


def _apply_glow(img, ramp):
    """Composite blurred copies of the brightest pixels behind the sprite."""
    bright = Image.new("RGBA", img.size, (0, 0, 0, 0))
    bp, sp = bright.load(), img.load()
    w, h = img.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = sp[x, y]
            if not a:
                continue
            if (r, g, b) == ramp[4]:
                bp[x, y] = (r, g, b, 255)
            elif (r, g, b) == ramp[3]:
                bp[x, y] = (r, g, b, 80)

    out = Image.new("RGBA", img.size, (0, 0, 0, 0))
    # Kept deliberately restrained: a stronger bloom swallows the body shading
    # on the smaller archetypes, which are only ~13px across.
    for radius, strength in ((4.5, 0.40), (1.7, 0.50)):  # wide halo, then hot core
        layer = bright.filter(ImageFilter.GaussianBlur(radius))
        layer.putalpha(layer.getchannel("A").point(lambda v: min(255, int(v * strength))))
        out = Image.alpha_composite(out, layer)
    return Image.alpha_composite(out, img)
