#!/usr/bin/env python3
"""Generate PackTrace's opening sound effects.

Every sound here is synthesised from scratch (noise, sine partials, envelopes).
Nothing is sampled, downloaded or derived from any game, app or video, so the
files are original to PackTrace. The generator uses only the Python standard
library and a fixed random seed per sound, so running it again produces the same
bytes on any machine with the same Python.

Usage:
    /usr/bin/python3 scripts/generate-opening-sounds.py            # write the files
    /usr/bin/python3 scripts/generate-opening-sounds.py --check    # compare with the committed files

Output: Sources/PackTraceUI/Resources/sounds/<cue>.wav (44.1 kHz, 16-bit, mono).
The cue names match `OpeningSoundCue.resourceName` in the app.
"""

import math
import os
import random
import struct
import sys
import wave

RATE = 44_100
OUT_DIR = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "Sources", "PackTraceUI", "Resources", "sounds"
)


# ---------------------------------------------------------------- building blocks

def silence(seconds):
    return [0.0] * int(RATE * seconds)


def mix_into(target, source, start_seconds=0.0, gain=1.0):
    start = int(RATE * start_seconds)
    needed = start + len(source)
    if needed > len(target):
        target.extend([0.0] * (needed - len(target)))
    for i, value in enumerate(source):
        target[start + i] += value * gain
    return target


def envelope(n, attack, release, curve=4.0):
    """Linear attack, exponential-ish release, both in seconds."""
    a = max(1, int(RATE * attack))
    r = max(1, int(RATE * release))
    out = []
    for i in range(n):
        if i < a:
            level = i / a
        else:
            t = min(1.0, (i - a) / r)
            level = math.exp(-curve * t) * (1.0 - t) + 0.0
        out.append(level)
    return out


def sine_note(freq, seconds, attack=0.004, release=None, partials=((1, 1.0),), detune=0.0):
    n = int(RATE * seconds)
    env = envelope(n, attack, release if release is not None else seconds)
    out = []
    for i in range(n):
        t = i / RATE
        value = 0.0
        for multiple, amp in partials:
            value += amp * math.sin(2 * math.pi * freq * multiple * t)
            if detune:
                value += amp * 0.5 * math.sin(2 * math.pi * freq * multiple * (1 + detune) * t)
        out.append(value * env[i])
    return out


def noise(seconds, rng):
    return [rng.uniform(-1.0, 1.0) for _ in range(int(RATE * seconds))]


def one_pole_lowpass(samples, cutoff):
    """cutoff may be a number or a function of the sample index."""
    out = []
    y = 0.0
    for i, x in enumerate(samples):
        fc = cutoff(i) if callable(cutoff) else cutoff
        alpha = 1.0 - math.exp(-2 * math.pi * fc / RATE)
        y += alpha * (x - y)
        out.append(y)
    return out


def highpass(samples, cutoff):
    low = one_pole_lowpass(samples, cutoff)
    return [x - l for x, l in zip(samples, low)]


def bandpass(samples, low, high):
    return one_pole_lowpass(highpass(samples, low), high)


def apply(samples, env):
    return [s * e for s, e in zip(samples, env)]


def fade_edges(samples, seconds=0.004):
    """Short fades on both ends so no file starts or stops with a click."""
    n = len(samples)
    f = min(n // 2, max(1, int(RATE * seconds)))
    out = list(samples)
    for i in range(f):
        g = i / f
        out[i] *= g
        out[n - 1 - i] *= g
    return out


def normalise(samples, peak_db):
    peak = max(1e-9, max(abs(s) for s in samples))
    target = 10 ** (peak_db / 20)
    return [s * target / peak for s in samples]


def to_wav_bytes(samples):
    frames = bytearray()
    for s in samples:
        v = int(round(max(-1.0, min(1.0, s)) * 32767))
        frames += struct.pack("<h", v)
    return bytes(frames)


# ---------------------------------------------------------------- the sounds

def pack_tear():
    """Paper-like tear: a band of filtered noise whose grain gets denser, with a
    few sharp crackles on top, then a quick fall-off as the strip comes away."""
    rng = random.Random(1101)
    length = 0.42
    base = bandpass(noise(length, rng), 900, 5200)
    n = len(base)
    # Density rises to the break at ~70% and falls away after it.
    grain = []
    for i in range(n):
        t = i / n
        rise = min(1.0, t / 0.7)
        fall = 1.0 if t < 0.7 else max(0.0, 1 - (t - 0.7) / 0.3) ** 2
        flutter = 0.55 + 0.45 * abs(math.sin(2 * math.pi * (38 + 60 * t) * t))
        grain.append(rise * fall * flutter)
    body = apply(base, grain)
    # Crackles: tiny high bursts at random points before the break.
    for _ in range(14):
        at = rng.uniform(0.05, 0.3)
        click = highpass(noise(0.006, rng), 2500)
        click = apply(click, envelope(len(click), 0.0005, 0.005, curve=6))
        mix_into(body, click, at, gain=rng.uniform(0.6, 1.2))
    return normalise(fade_edges(body), -7.0)


def card_slide():
    """Soft friction: low-passed noise whose brightness rises and falls, quiet."""
    rng = random.Random(2202)
    length = 0.24
    raw = noise(length, rng)
    n = len(raw)
    swept = one_pole_lowpass(raw, lambda i: 700 + 2600 * math.sin(math.pi * i / n))
    swept = highpass(swept, 180)
    env = [math.sin(math.pi * i / n) ** 1.5 for i in range(n)]
    return normalise(fade_edges(apply(swept, env)), -14.0)


def card_flip():
    """A light snap: a short bright tick over a small airy whoosh."""
    rng = random.Random(3303)
    out = silence(0.16)
    whoosh = one_pole_lowpass(highpass(noise(0.12, rng), 500), 3800)
    n = len(whoosh)
    whoosh = apply(whoosh, [math.sin(math.pi * i / n) ** 2 for i in range(n)])
    mix_into(out, whoosh, 0.0, gain=0.55)
    tick = highpass(noise(0.012, rng), 3000)
    tick = apply(tick, envelope(len(tick), 0.0006, 0.011, curve=7))
    mix_into(out, tick, 0.07, gain=1.0)
    thump = sine_note(210, 0.05, attack=0.001, release=0.045)
    mix_into(out, thump, 0.07, gain=0.35)
    return normalise(fade_edges(out), -12.0)


BELL = ((1, 1.0), (2, 0.28), (3, 0.08), (4.2, 0.05))


def rare_reveal():
    """Three rising bell notes (a major triad), each ringing out."""
    out = silence(0.8)
    notes = [(1046.50, 0.0), (1318.51, 0.075), (1567.98, 0.15)]  # C6 E6 G6
    for freq, at in notes:
        mix_into(out, sine_note(freq, 0.6, attack=0.003, release=0.58, partials=BELL), at, gain=0.6)
    return normalise(fade_edges(out), -8.0)


def special_reveal():
    """A wider chime: four notes over two octaves with a slow shimmer."""
    rng = random.Random(5505)
    out = silence(1.15)
    notes = [(783.99, 0.0), (1046.50, 0.06), (1318.51, 0.12), (2093.00, 0.19)]  # G5 C6 E6 C7
    for freq, at in notes:
        mix_into(
            out,
            sine_note(freq, 0.9, attack=0.004, release=0.88, partials=BELL, detune=0.0035),
            at,
            gain=0.5,
        )
    shimmer = bandpass(noise(0.9, rng), 5000, 11000)
    n = len(shimmer)
    shimmer = apply(shimmer, [math.sin(math.pi * i / n) ** 3 for i in range(n)])
    mix_into(out, shimmer, 0.12, gain=0.18)
    return normalise(fade_edges(out), -7.0)


def summary():
    """A short resolve: a dominant dyad settling into a soft major chord."""
    out = silence(1.0)
    soft = ((1, 1.0), (2, 0.18), (3, 0.05))
    for freq in (587.33, 783.99):  # D5 G5
        mix_into(out, sine_note(freq, 0.22, attack=0.012, release=0.2, partials=soft), 0.0, gain=0.35)
    for freq in (523.25, 659.25, 783.99, 1046.50):  # C5 E5 G5 C6
        mix_into(out, sine_note(freq, 0.75, attack=0.02, release=0.72, partials=soft), 0.16, gain=0.3)
    return normalise(fade_edges(out), -10.0)


SOUNDS = {
    "pack-tear": pack_tear,
    "card-slide": card_slide,
    "card-flip": card_flip,
    "rare-reveal": rare_reveal,
    "special-reveal": special_reveal,
    "summary": summary,
}


def render(name):
    samples = SOUNDS[name]()
    buffer = bytearray()
    # Written through the wave module into memory, so --check can compare bytes.
    import io

    stream = io.BytesIO()
    with wave.open(stream, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(to_wav_bytes(samples))
    buffer += stream.getvalue()
    return bytes(buffer)


def main(argv):
    check = "--check" in argv
    os.makedirs(OUT_DIR, exist_ok=True)
    mismatched = []
    for name in SOUNDS:
        data = render(name)
        path = os.path.normpath(os.path.join(OUT_DIR, name + ".wav"))
        seconds = (len(data) - 44) / 2 / RATE
        if check:
            try:
                with open(path, "rb") as handle:
                    same = handle.read() == data
            except FileNotFoundError:
                same = False
            print(f"{'ok      ' if same else 'DIFFERS '} {name}.wav ({seconds:.2f}s)")
            if not same:
                mismatched.append(name)
        else:
            with open(path, "wb") as handle:
                handle.write(data)
            print(f"wrote {path} ({seconds:.2f}s, {len(data)} bytes)")
    if mismatched:
        print("regenerate with: /usr/bin/python3 scripts/generate-opening-sounds.py")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
