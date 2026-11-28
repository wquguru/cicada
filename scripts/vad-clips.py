#!/usr/bin/env python3
import json
import math
import os
import random
import subprocess
import sys
import tempfile
import wave

RATE = 48000
OUT = sys.argv[1] if len(sys.argv) > 1 else "build/vad-eval"

LINES = {
    "Samantha": [
        "Let's start with the quarterly numbers.",
        "Revenue grew by twelve percent, mostly from the new region.",
        "Can everyone hear me okay?",
        "We should ship the update before the end of the month, but only if testing is done.",
        "Thanks, that's all from me.",
    ],
    "Tingting": [
        "我们先看一下这个季度的数据。",
        "收入增长了百分之十二，主要来自新的市场。",
        "大家能听到我说话吗？",
        "如果测试完成了，我们月底之前发布更新。",
        "好的，我这边就这些。",
    ],
}


RINGTONES = "/System/Library/PrivateFrameworks/ToneLibrary.framework/Versions/A/Resources/Ringtones"
ALERTS = "/System/Library/Sounds"


def read(path):
    with tempfile.TemporaryDirectory() as d:
        wav = os.path.join(d, "a.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", path, wav], check=True)
        with wave.open(wav) as w:
            raw = w.readframes(w.getnframes())
    return [int.from_bytes(raw[i:i + 2], "little", signed=True) / 32768 for i in range(0, len(raw), 2)]


def say(voice, text):
    with tempfile.TemporaryDirectory() as d:
        aiff = os.path.join(d, "a.aiff")
        subprocess.run(["say", "-v", voice, "-o", aiff, text], check=True)
        x = read(aiff)
    loud = [i for i, v in enumerate(x) if abs(v) > 0.003]
    return x[loud[0]:loud[-1] + 1]


def scaled(x, rms_db):
    rms = math.sqrt(sum(v * v for v in x) / len(x)) or 1
    k = 10 ** (rms_db / 20) / rms
    return [v * k for v in x]


def silence(seconds):
    return [0.0] * int(seconds * RATE)


def typing(seconds, rng, level=0.25):
    x = silence(seconds)
    t = rng.uniform(0.05, 0.2)
    while t < seconds - 0.02:
        i, amp = int(t * RATE), level * rng.uniform(0.5, 1)
        for k in range(int(0.006 * RATE)):
            x[i + k] += amp * math.exp(-k / (0.0015 * RATE)) * rng.uniform(-1, 1)
        t += rng.uniform(0.12, 0.33)
    return x


def ding(seconds):
    x = silence(seconds)
    for start, f in ((0.1, 880), (0.3, 1320)):
        i = int(start * RATE)
        if start + 0.2 > seconds:
            break
        for k in range(int(0.15 * RATE)):
            x[i + k] = 0.2 * math.sin(2 * math.pi * f * k / RATE) * math.exp(-k / (0.08 * RATE))
    return x


def music(seconds):
    x = silence(seconds)
    chords = [(261.6, 329.6, 392.0), (220.0, 261.6, 329.6), (174.6, 220.0, 261.6), (196.0, 246.9, 293.7)]
    beat = int(0.5 * RATE)
    for i in range(len(x)):
        c = chords[(i // beat) % len(chords)]
        env = 0.6 + 0.4 * math.exp(-(i % beat) / (0.15 * RATE))
        x[i] = env * sum(0.03 * math.sin(2 * math.pi * f * h * i / RATE) / h for f in c for h in (1, 2, 3))
    return x


def looped(sound, seconds, rms_db):
    n = int(seconds * RATE)
    base = scaled(sound, rms_db)
    return [base[i % len(base)] for i in range(n)]


def alert(sounds):
    def fill(seconds, rng):
        x = silence(seconds)
        a = scaled(rng.choice(sounds), -22)[:len(x) - int(0.1 * RATE)]
        x[int(0.05 * RATE):int(0.05 * RATE) + len(a)] = a
        return x
    return fill


def fan(n, rng, rms_db):
    y, out = 0.0, []
    for _ in range(n):
        y = 0.97 * y + 0.03 * rng.uniform(-1, 1)
        out.append(y)
    return scaled(out, rms_db)


def build(name, source, voice, gaps, speech_db, filler=None, noise_db=None, bed=None, seed=1, lines=5):
    rng = random.Random(seed)
    lines = [scaled(l, speech_db) for l in SPEECH[voice][:lines]]
    x, speech = silence(1.0), []
    for i, line in enumerate(lines):
        speech.append([len(x) / RATE, (len(x) + len(line)) / RATE])
        x += line
        g = gaps[i % len(gaps)]
        x += filler(g, rng) if filler else silence(g)
    if noise_db is not None:
        x = [a + b for a, b in zip(x, fan(len(x), rng, noise_db))]
    if bed is not None:
        x = [a + b for a, b in zip(x, bed(len(x) / RATE))]
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(int(max(-1, min(1, v)) * 32767).to_bytes(2, "little", signed=True) for v in x))
    with open(os.path.join(OUT, name + ".json"), "w") as f:
        json.dump({"source": source, "speech": [[round(s, 3), round(e, 3)] for s, e in speech]}, f)
    print(f"{name}: {len(x) / RATE:.1f} s, {len(speech)} lines")


os.makedirs(OUT, exist_ok=True)
SPEECH = {v: [say(v, t) for t in lines] for v, lines in LINES.items()}
GAPS = [0.4, 2.2, 0.8, 3.0, 1.6]
tones = [read(os.path.join(RINGTONES, f)) for f in ("Marimba.m4r", "Blues.m4r", "Old Phone.m4r")
         if os.path.exists(os.path.join(RINGTONES, f))]
alerts = [read(os.path.join(ALERTS, f)) for f in ("Glass.aiff", "Ping.aiff", "Submarine.aiff", "Hero.aiff")
          if os.path.exists(os.path.join(ALERTS, f))]
for v, tag in (("Samantha", "en"), ("Tingting", "zh")):
    if tones:
        build(f"system-ringtone-{tag}", "system", v, GAPS, -20,
              filler=lambda s, r: looped(r.choice(tones), s, -24))
        build(f"system-overmusic-{tag}", "system", v, GAPS, -20, bed=lambda s: looped(tones[1 % len(tones)], s, -32))
        build(f"system-hold-{tag}", "system", v, [30.0], -20, filler=lambda s, r: looped(tones[0], s, -24), lines=2)
    if alerts:
        build(f"system-alert-{tag}", "system", v, GAPS, -20, filler=alert(alerts))
    build(f"system-clean-{tag}", "system", v, GAPS, -20)
    build(f"system-typing-{tag}", "system", v, GAPS, -20, filler=typing)
    build(f"system-ding-{tag}", "system", v, GAPS, -20, filler=lambda s, r: ding(s))
    build(f"system-music-{tag}", "system", v, GAPS, -20, filler=lambda s, r: music(s))
    build(f"room-near-{tag}", "room", v, GAPS, -24, noise_db=-50)
    build(f"room-far-{tag}", "room", v, GAPS, -40, noise_db=-52)
    build(f"room-typing-{tag}", "room", v, GAPS, -28, filler=lambda s, r: typing(s, r, 0.08), noise_db=-50)
