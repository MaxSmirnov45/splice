# SPLICE

A top-down survival game about evolution — yours and the swarm's.

Built with Flutter + Flame. Every sprite, sound, and icon is generated from
code in `tools/`; the repository contains no third-party art or audio.

---

## The mechanic

Abilities are not picked from a list. Each one is a **genome**:

| Slot | Meaning | Count |
|---|---|---|
| **Vector** | how it reaches an enemy — bolt, orbit, aura, beam, mine, burst, chain, tether, wave, swarm | 10 |
| **Payload** | what it does on contact — kinetic, burn, frost, corrode, shock, bleed, void | 7 |
| **Trigger** | what makes it fire — timed, on-kill, on-hurt, while-moving, while-still, on-crit, while-wounded, on-dodge | 8 |
| **Riders** | stacking modifiers — amplify, rapid, split, pierce, seek, reach, weight, ferment, bloom, leech, echo, greed | unbounded |

On level up you either **absorb a wild spore** (stay broad) or **splice two
abilities** into one child, consuming both parents (go deep).

A child always visibly carries **both** parents. Differing vectors become a
primary and a secondary, and the ability literally fires both — an Orbit
spliced with a Beam orbits *and* fires a beam, applying both payloads. Matching
vectors have nothing to hybridise, so the lineage **concentrates** instead: no
secondary, but a damage bonus. Hybrid vigour buys coverage; pure lineage buys
power.

Rider stacks grow **sublinearly but without a ceiling**
(`perStack × n^exponent`), so progression is genuinely open-ended rather than
capping out. Measured growth is ~1.19× per generation.

Abilities also gain a **visual tier** from generation and rider stacks. Deeper
lineages accumulate structure on screen — orbiting motes, then a halo, then a
counter-rotating pair, then a pulsing core — so evolution is visible in play
and not just in the menu.

### The counter-pressure

The swarm adapts. Every 14 seconds, whichever damage type has done the most
work gains resistance, up to 72%, while everything else decays back toward
zero. Leaning on one payload strangles you. `corrode` strips resistance and
`void` ignores it entirely — those are the escape valves.

---

## Layout

```
lib/src/
  core/      rng (seeded xorshift), save data, audio playback
  genome/    gene definitions, crossover, mutation, derived stats
  game/      simulation, ability runtime, spatial hash, entity pools
  render/    texture atlas, sprite batch, world renderer
  ui/        title, HUD, splice screen, genome-derived sigils
tools/       Python generators (sprites, atlas, icon, audio) + balance scripts
```

The entire scene renders in one `drawRawAtlas` call per blend mode. Entities
live in fixed-capacity pools and never allocate during play. Collision and
separation go through a zero-allocation uniform grid.

Measured simulation cost: **0.06 ms/frame** with 400 enemies, **0.13 ms** at
the 700-entity pool ceiling, against a 16.7 ms budget.

---

## Regenerating assets

```sh
python3 tools/preview.py    # sprite contact sheets for visual review -> art/
python3 tools/atlas.py      # texture atlas + manifest -> assets/
python3 tools/icon.py       # app icon -> art/
python3 tools/audio.py      # sound effects -> assets/sfx/
dart run flutter_launcher_icons
```

## Balance tooling

```sh
dart run tools/curve.dart   # median power curve across 200 spliced lineages
flutter test                # includes a headless 12-minute simulated run
```

## Running

```sh
flutter run                                   # normal
flutter run --dart-define=SPLICE_DEMO=true    # auto-start, evolved loadout,
                                              # scripted movement (screenshots)
```

## Shipping

See [STORE.md](STORE.md) for release builds and the submission checklist,
including the parts that need your accounts and money.
