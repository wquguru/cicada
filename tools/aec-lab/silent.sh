#!/bin/zsh
# silent.sh: a press nobody spoke in, during the meeting (gate 1's echo-only recording at 56/100 %):
# AEC3 linear output and full output at 16 kHz, reference 150 ms early, written for ming.sh.
cd "${0:A:h}"
W=work
wav() { python3 -I -c "import wave; w=wave.open('$2','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(${3:-16000}); w.writeframes(open('$1','rb').read())"; }
python3 align.py $W/far16000.wav $W/mic_plain16.wav 16000 $W -150
LINEAR=1 ./aec 16000 $W/ref.raw $W/mic.raw $W/s16.raw
wav $W/s16.raw.lin16.raw $W/s_lin.wav
wav $W/s16.raw $W/s_full.wav
wav $W/s16.raw.hyb16.raw $W/s_hyb.wav
cp $W/mic_plain16.wav $W/s_plain.wav
