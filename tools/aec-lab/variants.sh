#!/bin/zsh
# variants.sh: from the last aecDump (a real double-talk round), AEC3 outputs to score through Ming:
# v_t0 (default), v_t3 (gentlest suppressor), v_lin (linear filter only, 16 kHz).
cd "${0:A:h}"
W=work
wav() { python3 -I -c "import wave; w=wave.open('$2','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(${3:-48000}); w.writeframes(open('$1','rb').read())"; }
python3 gate3.py $W 80 >/dev/null
for t in 0 3; do TUNE=$t ./aec 48000 $W/ref.raw $W/mic.raw $W/v.raw >/dev/null; wav $W/v.raw $W/v_t$t.wav; done
wav $W/ref.raw $W/ref.48.wav; afconvert -f WAVE -d LEI16@16000 -c 1 $W/ref.48.wav $W/ref.16.wav
wav $W/mic.raw $W/mic.48.wav; afconvert -f WAVE -d LEI16@16000 -c 1 $W/mic.48.wav $W/mic.16.wav
python3 -I -c "
import wave
for n in ['ref','mic']:
    w=wave.open('$W/'+n+'.16.wav'); open('$W/'+n+'.16.raw','wb').write(w.readframes(w.getnframes()))"
LINEAR=1 ./aec 16000 $W/ref.16.raw $W/mic.16.raw $W/v16.raw >/dev/null
wav $W/v16.raw.lin16.raw $W/v_lin.wav 16000
wav $W/v16.raw.hyb16.raw $W/v_hyb.wav 16000
wav $W/v16.raw $W/v_full16.wav 16000
ls -la $W/v_*.wav | awk '{print $5, $9}'
