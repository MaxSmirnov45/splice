"""Synthesize the game's sound effects and ambient bed.

Everything is generated from scratch — no samples, no licensing. The palette is
deliberately soft: sines and triangles with short envelopes rather than harsh
square waves, because a survivors-like fires hundreds of sounds a minute and
anything sharp becomes fatiguing within a minute of play.

Outputs 22.05kHz 16-bit mono WAVs into assets/sfx/.
"""

import math
import os
import subprocess
import random
import struct
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "assets", "sfx")

RATE = 22050


def write_wav(name, samples, peak=0.62):
    """Normalise to a headroom-safe peak and write 16-bit mono."""
    top = max(abs(s) for s in samples) or 1.0
    gain = peak / top
    frames = b"".join(
        struct.pack("<h", int(max(-1.0, min(1.0, s * gain)) * 32767)) for s in samples
    )
    path = os.path.join(OUT, f"{name}.wav")
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(frames)
    return path


def env(i, n, attack=0.01, release=0.6, curve=2.0):
    """Attack-decay envelope in 0..1. Always reaches zero, so nothing clicks."""
    t = i / n
    a = min(1.0, t / attack) if attack > 0 else 1.0
    r = max(0.0, 1.0 - max(0.0, (t - attack) / max(1e-6, release)))
    return a * (r ** curve)


def tone(freq, dur, shape="sine", sweep=1.0, detune=0.0):
    """A single voice with an optional pitch sweep across its duration."""
    n = int(RATE * dur)
    out = []
    phase = 0.0
    phase2 = 0.0
    for i in range(n):
        f = freq * (sweep ** (i / n))
        phase += 2 * math.pi * f / RATE
        phase2 += 2 * math.pi * f * (1 + detune) / RATE
        if shape == "sine":
            v = math.sin(phase)
        elif shape == "tri":
            v = 2 / math.pi * math.asin(math.sin(phase))
        else:  # soft saw
            v = math.sin(phase) + 0.35 * math.sin(phase * 2)
        if detune:
            v = (v + math.sin(phase2)) * 0.5
        out.append(v)
    return out


def noise(dur, lowpass=0.35):
    """One-pole lowpassed noise. Cheap 'thud' and 'splat' material."""
    n = int(RATE * dur)
    out = []
    last = 0.0
    rnd = random.Random(0xBEEF)
    for _ in range(n):
        last += lowpass * (rnd.uniform(-1, 1) - last)
        out.append(last)
    return out


def mix(*layers):
    n = max(len(l) for l in layers)
    out = [0.0] * n
    for l in layers:
        for i, v in enumerate(l):
            out[i] += v
    return out


def shaped(samples, attack=0.01, release=0.6, curve=2.0):
    n = len(samples)
    return [s * env(i, n, attack, release, curve) for i, s in enumerate(samples)]


# --- the set ---------------------------------------------------------------


def sfx_shoot():
    # Short, soft, and pitched high enough to sit above the ambient bed.
    return shaped(tone(680, 0.07, "tri", sweep=0.55), attack=0.02, release=0.8, curve=2.2)


def sfx_hit():
    # Percussive but dull, so hundreds per minute do not fatigue.
    return shaped(
        mix(noise(0.05, 0.5), tone(320, 0.05, "sine", sweep=0.6)),
        attack=0.01, release=0.9, curve=3.0,
    )


def sfx_kill():
    # A wet pop: falling tone with a noise transient.
    return shaped(
        mix(tone(420, 0.16, "sine", sweep=0.32), [v * 0.55 for v in noise(0.16, 0.28)]),
        attack=0.01, release=0.85, curve=2.4,
    )


def sfx_pickup():
    # Rising, tiny, unmistakably positive.
    return shaped(tone(880, 0.06, "sine", sweep=1.55), attack=0.05, release=0.7)


def sfx_hurt():
    # Low and blunt. The only sound allowed to be ugly.
    return shaped(
        mix(tone(110, 0.28, "saw", sweep=0.55), [v * 0.7 for v in noise(0.28, 0.12)]),
        attack=0.005, release=0.75, curve=1.6,
    )


def sfx_levelup():
    # Rising minor-pentatonic arpeggio: unambiguous "stop and choose".
    out = []
    for i, f in enumerate([440, 587, 659, 880]):
        note = shaped(tone(f, 0.13, "tri", detune=0.004), attack=0.04, release=0.75)
        out.extend([v * (0.7 + 0.1 * i) for v in note])
    return out


def sfx_splice():
    # Two detuned voices converging into one — the mechanic, as a sound.
    n = int(RATE * 0.55)
    out = []
    pa = pb = 0.0
    for i in range(n):
        t = i / n
        fa = 330 * (1 + 0.22 * (1 - t))
        fb = 330 * (1 - 0.22 * (1 - t))
        pa += 2 * math.pi * fa / RATE
        pb += 2 * math.pi * fb / RATE
        out.append((math.sin(pa) + math.sin(pb)) * 0.5)
    return shaped(out, attack=0.06, release=0.7, curve=1.8)


def sfx_adapt():
    # Descending, slightly sour: the swarm is now resistant.
    return shaped(tone(300, 0.5, "saw", sweep=0.6, detune=0.01),
                  attack=0.05, release=0.7, curve=1.5)


# --- music -----------------------------------------------------------------
#
# The previous bed was four sine layers at 55/82/110/247 Hz. On a phone
# speaker that is very nearly silence: small drivers roll off steeply below
# roughly 400 Hz, so the fundamentals never reach the listener at all. Anything
# meant to be *heard* on a handset has to carry its identity in the 300 Hz to
# 4 kHz band, which is why this track leads with a plucked arpeggio and gives
# the bass a sawtooth rich enough that its harmonics imply the root even when
# the root itself is inaudible.

# i - VI - III - VII in A minor. Two bars each.
PROGRESSION = [
    ("Am", [440.00, 523.25, 659.25], 220.00),
    ("F",  [349.23, 440.00, 523.25], 174.61),
    ("C",  [523.25, 659.25, 783.99], 261.63),
    ("G",  [392.00, 493.88, 587.33], 196.00),
]


def _mix_into(buf, start, samples, gain=1.0):
    n = len(buf)
    for i, v in enumerate(samples):
        # Wrap rather than truncate, so a tail crossing the end of the loop
        # lands at the start and the seam stays inaudible.
        buf[(start + i) % n] += v * gain


def pluck(freq, dur, bright=0.55):
    """Short decaying tone with strong harmonics — the audible lead voice."""
    n = int(RATE * dur)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / n
        phase += 2 * math.pi * freq / RATE
        # Triangle plus a touch of square: plenty of upper harmonics, which is
        # what actually survives a small speaker.
        v = (2 / math.pi) * math.asin(math.sin(phase))
        v += bright * (0.5 if math.sin(phase * 2) > 0 else -0.5) * 0.35
        out.append(v * math.exp(-4.5 * t))
    return out


def bass(freq, dur):
    """Sawtooth bass, lowpassed just enough to stay warm but keep harmonics."""
    n = int(RATE * dur)
    out = []
    phase = 0.0
    last = 0.0
    for i in range(n):
        t = i / n
        phase += freq / RATE
        phase -= math.floor(phase)
        saw = 2 * phase - 1
        last += 0.22 * (saw - last)
        env = min(1.0, t * 40) * math.exp(-2.2 * t)
        out.append(last * env)
    return out


def pad(freqs, dur):
    """Sustained chord with a slow swell, sitting under the lead."""
    n = int(RATE * dur)
    out = [0.0] * n
    for f in freqs:
        phase = 0.0
        phase2 = 0.0
        for i in range(n):
            t = i / n
            phase += 2 * math.pi * f / RATE
            phase2 += 2 * math.pi * f * 1.004 / RATE  # slight detune, chorused
            env = min(1.0, t * 6) * min(1.0, (1 - t) * 6)
            out[i] += (math.sin(phase) + math.sin(phase2)) * 0.5 * env
    return [v / max(1, len(freqs)) for v in out]


def hat(dur=0.05):
    """Filtered noise tick. Carries the pulse where a kick cannot."""
    n = int(RATE * dur)
    rnd = random.Random(31337)
    out = []
    last = 0.0
    for i in range(n):
        t = i / n
        white = rnd.uniform(-1, 1)
        # One-pole highpass: keeps only the bright end.
        last += 0.7 * (white - last)
        out.append((white - last) * math.exp(-28 * t))
    return out


def kick(dur=0.16):
    """Pitch-swept thump with a click, so it reads even without deep bass."""
    n = int(RATE * dur)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / n
        f = 150 * math.exp(-7 * t) + 48
        phase += 2 * math.pi * f / RATE
        click = math.exp(-90 * t) * 0.35
        out.append((math.sin(phase) + click) * math.exp(-5 * t))
    return out


def music(bpm=88, bars=8):
    """A loopable backing track.

    Written to be audible on a phone rather than atmospheric on studio
    monitors: the arpeggio and hats live where small speakers actually
    reproduce sound, and the loop length is an exact number of beats so the
    seam falls on a downbeat.
    """
    spb = 60.0 / bpm
    total = int(RATE * spb * 4 * bars)
    out = [0.0] * total
    step = spb / 4  # sixteenth notes

    for bar in range(bars):
        chord_index = (bar // 2) % len(PROGRESSION)
        _, tones, root = PROGRESSION[chord_index]
        bar_start = int(RATE * spb * 4 * bar)

        # Pad across the whole bar.
        _mix_into(out, bar_start, pad(tones, spb * 4), 0.30)

        # Bass on beats 1 and 3, with the octave on 3 for movement.
        _mix_into(out, bar_start, bass(root, spb * 1.6), 0.55)
        _mix_into(out, bar_start + int(RATE * spb * 2), bass(root * 1.5, spb * 1.4), 0.42)

        for s in range(16):
            at = bar_start + int(RATE * step * s)

            # Sixteenth arpeggio, skipping a couple of steps so it breathes.
            if s % 2 == 0 and s not in (6, 14):
                note = tones[(s // 2) % len(tones)]
                # Lift every other cycle an octave for a sense of motion.
                if (s // 2) % 4 == 3:
                    note *= 2
                _mix_into(out, at, pluck(note, step * 2.2), 0.34)

            # Hats on the offbeats.
            if s % 4 == 2:
                _mix_into(out, at, hat(), 0.16)

            # Kick on 1 and the "and" of 3.
            if s == 0 or s == 10:
                _mix_into(out, at, kick(), 0.5)

    return out


def phone_audibility(samples, cutoff=400.0):
    """Fraction of signal energy above [cutoff], as a phone-speaker proxy.

    Small drivers roll off steeply in the low end, so energy below a few
    hundred Hz simply never reaches the listener. This is a crude one-pole
    high-pass, but it is enough to catch the failure mode where a track is
    "loud" in the file and inaudible on a handset.
    """
    rc = 1.0 / (2 * math.pi * cutoff)
    dt = 1.0 / RATE
    alpha = rc / (rc + dt)
    prev_in = prev_out = 0.0
    hp_sq = tot_sq = 0.0
    for x in samples:
        y = alpha * (prev_out + x - prev_in)
        prev_in, prev_out = x, y
        hp_sq += y * y
        tot_sq += x * x
    if tot_sq <= 0:
        return 0.0
    return math.sqrt(hp_sq / tot_sq)


def main():
    os.makedirs(OUT, exist_ok=True)
    built = {
        "shoot": sfx_shoot(),
        "hit": sfx_hit(),
        "kill": sfx_kill(),
        "pickup": sfx_pickup(),
        "hurt": sfx_hurt(),
        "levelup": sfx_levelup(),
        "splice": sfx_splice(),
        "adapt": sfx_adapt(),
    }
    total = 0
    for name, samples in built.items():
        path = write_wav(name, samples)
        total += os.path.getsize(path)
        print(f"  {name:<8} {len(samples) / RATE * 1000:6.0f} ms  "
              f"{os.path.getsize(path) / 1024:5.1f} KB")

    track = music()
    # Loud enough to be present without fighting the effects. The old bed sat
    # at 0.30 and was inaudible; most of that was frequency, not level, but it
    # was quiet too.
    path = write_wav("ambient", track, peak=0.72)
    ms = len(track) / RATE * 1000

    # The music is by far the largest asset, and on the web it is the single
    # biggest slice of first-load. AAC takes it from ~940 KB to ~170 KB, and
    # every platform the game targets decodes it natively. Short effects stay
    # as WAV: they are a few KB each, and a compressed format adds decoder
    # latency to sounds that need to fire instantly.
    m4a = os.path.join(OUT, "ambient.m4a")
    try:
        subprocess.run(
            ["afconvert", "-f", "m4af", "-d", "aac", "-b", "64000", path, m4a],
            check=True, capture_output=True)
        os.remove(path)
        path = m4a
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        print(f"  ! afconvert unavailable ({e}); shipping uncompressed music")
    total += os.path.getsize(path)
    print(f"  {'music':<8} {ms:6.0f} ms  {os.path.getsize(path) / 1024:5.1f} KB"
          f"  ({os.path.basename(path)})")
    print(f"total {total / 1024:.0f} KB")
    print(f"\nenergy above 400 Hz (phone-speaker proxy): "
          f"{phone_audibility(track) * 100:.0f}%")
    print("the previous bed was sines at 55/82/110/247 Hz — every fundamental "
          "at or below\nthat cutoff, which is why it could not be heard on a "
          "handset at any volume.")


if __name__ == "__main__":
    main()
