#!/usr/bin/env python3
"""dt.py <work> <near_gain_db> <at_s>: double talk offline. Adds the mic recording of the Chinese
sentence alone (work/nearmic.s16.wav, 48 kHz) into the echo-only mic (work/mic.raw, from gate3.py)
at <at_s>, scaled by <near_gain_db>; the reference (work/ref.raw) stays the English only.
Writes work/dtmic.raw and work/nearonly.raw (the same near placement with no echo, the ceiling)."""
import sys, wave
import numpy as np

w, g, at = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
with wave.open(f"{w}/nearmic.s16.wav") as f:
    near = np.frombuffer(f.readframes(f.getnframes()), np.int16).astype(np.float32)
mic = np.fromfile(f"{w}/mic.raw", np.int16).astype(np.float32)
near *= 10 ** (g / 20)
placed = np.zeros_like(mic)
i = int(at * 48000)
seg = near[: len(mic) - i]
placed[i: i + len(seg)] = seg
def rms_db(x): return 20 * np.log10(np.sqrt(np.mean(x[x != 0] ** 2)) / 32768 + 1e-12)
print(f"dt: near {rms_db(seg):.1f} dBFS rms, echo {rms_db(mic[i: i + len(seg)]):.1f} dBFS rms over the same span")
np.clip(mic + placed, -32768, 32767).astype(np.int16).tofile(f"{w}/dtmic.raw")
placed.astype(np.int16).tofile(f"{w}/nearonly.raw")
