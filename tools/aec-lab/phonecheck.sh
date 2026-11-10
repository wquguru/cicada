#!/bin/zsh
# The phone heard by the Mac's mic: record while it plays a Chinese sentence, transcribe zh-CN.
cd "${0:A:h}"
W=work
[[ -f $W/near.aiff ]] || say -v Tingting -o $W/near.aiff "我同意这个数字。设计那个岗位很急，周四之前我会回复。"
[[ -f $W/near.wav ]] || afconvert -f WAVE -d LEI16@48000 -c 1 $W/near.aiff $W/near.wav
./rec 8 $W/phone.wav &
sleep 1
python3 phone.py play $W/near.wav --at $(python3 -c "import time;print(time.time()+1)")
wait
afconvert -f WAVE -d LEI16@16000 -c 1 $W/phone.wav $W/phone16.wav
./transcribe $W/phone16.wav zh-CN 2>/dev/null
python3 - $W/phone16.wav <<'EOF'
import sys, wave, numpy as np
w = wave.open(sys.argv[1]); x = np.frombuffer(w.readframes(w.getnframes()), np.int16) / 32768
print(f"peak {20*np.log10(np.abs(x).max()+1e-9):.1f} dBFS")
EOF
