"""Render review sheets so the sprite algorithm can be judged by eye."""

import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from PIL import Image
from creature import ARCHETYPES, PALETTES, render_creature, BG

ART = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "art")
os.makedirs(ART, exist_ok=True)

# One palette per archetype keeps the roster readable: colour reads as species.
SPECIES_PALETTE = {
    "mote": "cyan", "crawler": "acid", "spiker": "blood", "floater": "void",
    "brute": "amber", "weaver": "magenta", "elite": "bone", "host": "spirit",
}


def roster(seeds=6, scale=5):
    """Grid: one archetype per row, several seeds across."""
    names = list(ARCHETYPES.keys())
    cell = max(ARCHETYPES[n]["size"] for n in names) + 18
    cw = cell * scale
    sheet = Image.new("RGBA", (seeds * cw, len(names) * cw), BG)
    for r, name in enumerate(names):
        for c in range(seeds):
            im = render_creature(name, SPECIES_PALETTE[name], seed=c * 7 + 1)
            big = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
            sheet.alpha_composite(big, (c * cw + (cw - big.width) // 2,
                                        r * cw + (cw - big.height) // 2))
    return sheet


def palette_sweep(archetype="crawler", scale=5):
    """Same creature across every palette, to check the ramps hold up."""
    pals = list(PALETTES.keys())
    cell = ARCHETYPES[archetype]["size"] + 18
    cw = cell * scale
    sheet = Image.new("RGBA", (len(pals) * cw, cw), BG)
    for i, p in enumerate(pals):
        im = render_creature(archetype, p, seed=3)
        big = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
        sheet.alpha_composite(big, (i * cw + (cw - big.width) // 2, (cw - big.height) // 2))
    return sheet


def actual_size(scale=3):
    """A mock crowd at true game scale — the only test that really matters."""
    layout = [("mote", 0), ("mote", 1), ("mote", 2), ("crawler", 0), ("crawler", 1),
              ("spiker", 0), ("floater", 0), ("weaver", 0), ("brute", 0), ("elite", 0),
              ("host", 0)]
    imgs = [(render_creature(n, SPECIES_PALETTE[n], seed=s * 7 + 1)) for n, s in layout]
    pad = 8
    w = sum(i.width * scale for i in imgs) + pad * (len(imgs) + 1)
    h = max(i.height * scale for i in imgs) + pad * 2
    sheet = Image.new("RGBA", (w, h), BG)
    x = pad
    for im in imgs:
        big = im.resize((im.width * scale, im.height * scale), Image.NEAREST)
        sheet.alpha_composite(big, (x, (h - big.height) // 2))
        x += big.width + pad
    return sheet


if __name__ == "__main__":
    roster().save(os.path.join(ART, "sheet_roster.png"))
    palette_sweep().save(os.path.join(ART, "sheet_palettes.png"))
    actual_size().save(os.path.join(ART, "sheet_actual.png"))
    print("wrote sheet_roster.png, sheet_palettes.png, sheet_actual.png")
