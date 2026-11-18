#!/usr/bin/env python3
"""Procedural audio for Trunkfall (iter1, team G). No samples, no third-party
material: every sound here is synthesised from sine / saw / square / noise, so
the files are ours to upload (assets/models/manifest.json, type Audio).

    python3 assets/audio/make-audio.py            # writes assets/audio/*.ogg

STYLE.md direction: bouncy brass and woodwinds, mice squeak in a pitch-shifted
chorus, boss themes add a kazoo layer, every telegraph has its own wind-up.
Loops are an exact number of bars so they loop seamlessly.
"""
import os
import subprocess
import sys
import wave

import numpy as np

SR = 22050
OUT = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)


def note_hz(n):
    return 440.0 * 2 ** ((n - 69) / 12)


def env(n, a=0.01, d=0.1, s=0.6, r=0.08):
    t = np.arange(n) / SR
    dur = n / SR
    e = np.ones(n) * s
    e[t < a] = t[t < a] / max(a, 1e-4)
    m = (t >= a) & (t < a + d)
    e[m] = 1 - (1 - s) * (t[m] - a) / d
    rel = t > dur - r
    e[rel] *= np.clip((dur - t[rel]) / r, 0, 1)
    return e


def lowpass(x, k):
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += k * (v - acc)
        y[i] = acc
    return y


def osc(kind, f, n, vib=0.0, vibf=5.5, duty=0.5):
    t = np.arange(n) / SR
    fr = f * (1 + vib * np.sin(2 * np.pi * vibf * t))
    ph = np.cumsum(fr) / SR
    if kind == "saw":
        return 2 * (ph % 1) - 1
    if kind == "square":
        return np.where((ph % 1) < duty, 1.0, -1.0)
    if kind == "tri":
        return 2 * np.abs(2 * (ph % 1) - 1) - 1
    return np.sin(2 * np.pi * ph)


def brass(f, n):
    x = osc("saw", f, n, vib=0.006) * 0.6 + osc("square", f * 0.5, n, duty=0.3) * 0.15
    return lowpass(x, 0.22) * env(n, 0.03, 0.12, 0.7, 0.05)


def wood(f, n):
    x = osc("square", f, n, vib=0.004, duty=0.25) * 0.5 + osc("sine", f * 2, n) * 0.2
    return lowpass(x, 0.3) * env(n, 0.02, 0.08, 0.6, 0.04)


def kazoo(f, n):
    x = osc("saw", f, n, vib=0.02, vibf=6.5)
    buzz = np.sign(np.sin(2 * np.pi * f * 3 * np.arange(n) / SR)) * 0.15
    return lowpass(x + buzz, 0.35) * env(n, 0.04, 0.1, 0.75, 0.05)


def bass(f, n):
    return osc("tri", f, n) * env(n, 0.005, 0.15, 0.5, 0.04)


def kick(n):
    t = np.arange(n) / SR
    f = 120 * np.exp(-t * 25) + 45
    return np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t * 9)


def snare(n):
    t = np.arange(n) / SR
    return (rng.uniform(-1, 1, n) * 0.7 + np.sin(2 * np.pi * 190 * t) * 0.3) * np.exp(-t * 18)


def hat(n):
    t = np.arange(n) / SR
    x = rng.uniform(-1, 1, n)
    return (x - lowpass(x, 0.5)) * np.exp(-t * 60)


def put(buf, start, x, gain):
    s = int(start)
    e = min(len(buf), s + len(x))
    if e > s:
        buf[s:e] += x[: e - s] * gain


def song(bpm, bars, chords, melody, counter, lead=brass, drums="straight", kaz=None):
    beat = 60 / bpm
    n = int(round(bars * 4 * beat * SR))
    mix = np.zeros(n)
    spb = beat * SR
    for bar in range(bars):
        root = chords[bar % len(chords)]
        for b in range(4):
            t0 = (bar * 4 + b) * spb
            # bass: root / fifth bounce on eighths
            for h, off in ((0, 0), (7, 0.5)):
                put(mix, t0 + off * spb, bass(note_hz(root - 24 + h), int(spb * 0.45)), 0.32)
            # chord stab on the off-beat (woodwind-ish)
            for iv in (0, 4 if root % 12 in (0, 5, 7) else 3, 7):
                put(mix, t0 + 0.5 * spb, wood(note_hz(root + iv), int(spb * 0.3)), 0.06)
            if drums:
                put(mix, t0, kick(int(spb * 0.6)), 0.55 if b % 2 == 0 else 0.25)
                if b % 2 == 1:
                    put(mix, t0, snare(int(spb * 0.4)), 0.3)
                put(mix, t0 + 0.5 * spb, hat(int(spb * 0.2)), 0.12)
                if drums == "busy":
                    put(mix, t0 + 0.25 * spb, hat(int(spb * 0.15)), 0.07)
                    put(mix, t0 + 0.75 * spb, hat(int(spb * 0.15)), 0.07)
    for voice, notes, gain in ((lead, melody, 0.28), (wood, counter, 0.12), (kaz, melody if kaz else [], 0.14)):
        if not voice:
            continue
        t = 0.0
        for nn, dur in notes:
            if nn is not None:
                put(mix, t * spb, voice(note_hz(nn + (12 if voice is wood else 0)), int(dur * spb * 0.95)), gain)
            t += dur
    # loop-safe: the tail of the bar-length buffer wraps into its start
    mix /= max(1e-6, np.max(np.abs(mix))) / 0.85
    return mix


def save(name, x, quality=4):
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    wav = os.path.join(OUT, name + ".wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    ogg = os.path.join(OUT, name + ".ogg")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "libvorbis", "-q:a", str(quality), ogg], check=True)
    os.remove(wav)
    print("wrote", ogg, os.path.getsize(ogg), "bytes")


def seq(pattern, base):
    out = []
    for p in pattern:
        if p is None:
            out.append((None, 0.5))
        else:
            n, d = p if isinstance(p, tuple) else (p, 0.5)
            out.append((None if n is None else base + n, d))
    return out


def music():
    # lobby: relaxed C major, 104 bpm, 8 bars
    C, F, G, Am = 60, 65, 67, 57
    mel = seq([0, 4, 7, (9, 1), 7, 4, (2, 1), 0, 2, 4, (7, 1.5), None, (5, 0.5), 4, 2, (0, 1), (4, 1), 7, 9, 7, 5, (4, 1), 2, 0, (2, 1.5), None,
               0, 4, 7, (12, 1), 11, 9, (7, 1), 5, 4, 2, (4, 1.5), None, 2, 4, 5, 7, (9, 1), 7, 5, (4, 1), (2, 1), (0, 2)], 72)
    cnt = seq([(None, 2), (7, 1), (4, 1)] * 8, 60)
    save("music_lobby", song(104, 8, [C, Am, F, G], mel, cnt, drums="straight"))
    # run: driving D minor-ish, 132 bpm, 8 bars
    Dm, Bb, F2, C2 = 62, 58, 65, 60
    mel = seq([0, 0, 3, 5, (7, 1), 5, 3, (2, 1), 0, 2, (3, 1.5), None, 5, 7, 8, 7, 5, 3, (5, 1), 7, 5, (3, 1), 2, 0, (2, 2),
               7, 7, 10, 12, (10, 1), 8, 7, (5, 1), 3, 5, (7, 1.5), None, 8, 7, 5, 3, 2, 3, (2, 1), (0, 1), None, None, (0, 1)], 74)
    cnt = seq([(0, 1), (3, 1), (7, 1), (3, 1)] * 8, 62)
    save("music_run", song(132, 8, [Dm, Bb, F2, C2], mel, cnt, drums="busy"))
    # boss: A minor, 144 bpm, kazoo doubling the lead (the running joke)
    Am2, F3, E3, Dm3 = 57, 65, 64, 62
    mel = seq([0, 3, 7, 3, 8, 7, 3, 0, (11, 1), 7, 4, (12, 1.5), None, 0, 3, 7, 10, 8, 7, 5, 3, (2, 1), 3, 2, (0, 2),
               12, 12, 11, 12, (15, 1), 12, 10, (8, 1), 7, 8, (7, 1.5), None, 5, 7, 8, 7, 5, 3, (2, 1), (-1, 1), (0, 2)], 69)
    cnt = seq([(0, 0.5), (12, 0.5)] * 32, 45)
    save("music_boss", song(144, 8, [Am2, F3, Dm3, E3], mel, cnt, drums="busy", kaz=kazoo))


def sfx():
    def env1(n, a, r):
        t = np.arange(n) / SR
        return np.clip(t / a, 0, 1) * np.exp(-t * r)

    # three squeaks (a chorus when layered by the controller's pitch variance)
    for i, (f0, f1, d) in enumerate(((1700, 2600, 0.11), (2100, 3000, 0.09), (1500, 2300, 0.14))):
        n = int(d * SR)
        t = np.arange(n) / SR
        f = f0 + (f1 - f0) * np.sin(np.pi * t / d) + 120 * np.sin(2 * np.pi * 38 * t)
        x = np.sin(2 * np.pi * np.cumsum(f) / SR) * env1(n, 0.008, 18)
        save("sfx_squeak%d" % (i + 1), x * 0.9)
    # elephant trumpet: a brassy glide up with growl
    n = int(0.75 * SR)
    t = np.arange(n) / SR
    f = 230 + 210 * np.clip(t / 0.25, 0, 1) - 60 * np.clip((t - 0.45) / 0.3, 0, 1)
    f *= 1 + 0.03 * np.sin(2 * np.pi * 28 * t)
    ph = np.cumsum(f) / SR
    x = (2 * (ph % 1) - 1) * 0.6 + np.sin(2 * np.pi * ph * 2) * 0.3 + rng.uniform(-1, 1, n) * 0.05
    x = lowpass(x, 0.3) * env1(n, 0.04, 2.2)
    save("sfx_trumpet", x)
    # stomp: deep thud + dust
    n = int(0.5 * SR)
    save("sfx_stomp", kick(n) * 0.9 + lowpass(rng.uniform(-1, 1, n), 0.05) * np.exp(-np.arange(n) / SR * 12) * 0.6)
    # telegraph wind-ups, one per pattern base
    n = int(0.7 * SR)
    t = np.arange(n) / SR
    rumble = lowpass(rng.uniform(-1, 1, n), 0.02) * 3 + np.sin(2 * np.pi * (40 + 30 * t) * t) * 0.5
    save("tele_slam", rumble * np.clip(t / 0.6, 0, 1) * 0.8)
    f = 300 + 900 * (t / 0.7) ** 2
    whine = lowpass(2 * ((np.cumsum(f) / SR) % 1) - 1, 0.25) * np.clip(t / 0.6, 0, 1)
    save("tele_charge", whine * 0.6)
    tick = np.zeros(n)
    for k in range(6):
        s = int(k * 0.1 * SR)
        m = int(0.03 * SR)
        tick[s : s + m] += np.sin(2 * np.pi * (900 + k * 120) * np.arange(m) / SR) * np.exp(-np.arange(m) / SR * 80)
    save("tele_volley", tick * 0.8)
    shimmer = sum(np.sin(2 * np.pi * fr * t + p) for fr, p in ((660, 0), (990, 1), (1320, 2))) / 3
    save("tele_summon", shimmer * np.clip(t / 0.5, 0, 1) * (0.6 + 0.4 * np.sin(2 * np.pi * 9 * t)) * 0.7)


if __name__ == "__main__":
    which = sys.argv[1] if len(sys.argv) > 1 else "all"
    if which in ("all", "sfx"):
        sfx()
    if which in ("all", "music"):
        music()
