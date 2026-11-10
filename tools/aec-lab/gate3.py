#!/usr/bin/env python3
"""gate3.py <outdir> [extra_lead_ms]: lines the app's tap up with its mic by host time (no correlation,
as the app would have to), writes outdir/ref.raw + mic.raw (s16 48 kHz), and prints how far the echo in
the mic lags the tap's timestamps (by correlation, for information only)."""
import json, sys, wave
import numpy as np

def read(p):
    import subprocess
    # AVAudioFile wrote float WAV; afconvert to s16 48 kHz first.
    subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@48000", "-c", "1", p, p + ".s16.wav"], check=True)
    with wave.open(p + ".s16.wav") as w:
        return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32)

out = sys.argv[1]
extra = float(sys.argv[2]) if len(sys.argv) > 2 else 0
info = json.load(open("/tmp/cicada-aec.json"))
tap, mic = read("/tmp/cicada-aec-tap.wav"), read("/tmp/cicada-aec-mic.wav")
rate = 48000
off = int(round((info["micMinusTapMs"] + extra) * rate / 1000))  # tap index for mic sample 0
ref = np.zeros(len(mic), np.float32)
for n0 in range(len(mic)):
    break
lo = max(0, -off)
seg = tap[max(0, off): max(0, off) + len(mic) - lo]
ref[lo: lo + len(seg)] = seg
n = 1 << int(np.ceil(np.log2(2 * len(mic))))
xc = np.fft.irfft(np.fft.rfft(mic, n) * np.conj(np.fft.rfft(ref, n)), n)
lags = np.concatenate([xc[-rate:], xc[: rate]])
lag = int(np.argmax(np.abs(lags))) - rate
print(f"gate3: mic starts {info['micMinusTapMs']:.1f} ms after the tap; echo lags the tap's time by {lag / rate * 1000:.0f} ms"
      f" (extra lead {extra:+.0f} ms); tap peak {20*np.log10(np.abs(tap).max()/32768+1e-9):.1f} dBFS")
ref.astype(np.int16).tofile(f"{out}/ref.raw")
mic.astype(np.int16).tofile(f"{out}/mic.raw")
