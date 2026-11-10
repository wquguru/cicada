#!/usr/bin/env python3
"""align.py <far.wav> <mic.wav> <rate> <outdir> [shift_ms]: both s16 mono at <rate>. Finds where the far
clip starts in the mic by cross-correlation, writes outdir/ref.raw (far placed at that offset plus
shift_ms, the way a reference that arrives early or late would be) and outdir/mic.raw."""
import sys, wave
import numpy as np

def read(p):
    with wave.open(p) as w:
        return np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32)

far, mic = read(sys.argv[1]), read(sys.argv[2])
rate, out = int(sys.argv[3]), sys.argv[4]
shift = int(float(sys.argv[5]) * rate / 1000) if len(sys.argv) > 5 else 0
n = 1 << int(np.ceil(np.log2(len(mic) + len(far))))
xc = np.fft.irfft(np.fft.rfft(mic, n) * np.conj(np.fft.rfft(far, n)), n)
lag = int(np.argmax(xc[: len(mic)]))
print(f"align: far starts {lag / rate * 1000:.0f} ms into the mic recording; reference shifted {shift / rate * 1000:+.0f} ms")
ref = np.zeros(len(mic), dtype=np.float32)
start = max(0, lag + shift)
seg = far[: max(0, len(mic) - start)]
ref[start : start + len(seg)] = seg
ref.astype(np.int16).tofile(f"{out}/ref.raw")
mic.astype(np.int16).tofile(f"{out}/mic.raw")
