#!/bin/zsh
# rt.sh <repo> <volume%> <rounds>: real double talk. The English meeting on the Mac speakers, the iPhone
# (phone.py) saying the Chinese sentence 3 s into it. Per round: (a) the dev build's aecDump (its tap +
# plain mic) → plain mic and AEC3 (host time +80 ms, TUNE 0 and 3) scored; (b) a VoiceProcessingIO
# recording (rec vpio) the same way. Chinese characters kept / English words leaked.
cd "${0:A:h}"
REPO=$1; VOL=$2; ROUNDS=${3:-1}; W=work
NEAR="我同意这个数字。设计那个岗位很急，周四之前我会回复。"
TEXT="Thanks everyone for joining. Our revenue grew twelve percent this quarter, mostly from enterprise customers in Europe. Marketing spent less than planned, and we hired four engineers. Next month we will launch the new pricing page and review the hiring plan for the second half of the year."
wav() { python3 -I -c "import wave; w=wave.open('$2','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(${3:-48000}); w.writeframes(open('$1','rb').read())"; }
zh() { python3 -I - "$NEAR" "$1" <<'EOF'
import sys
want = [c for c in sys.argv[1] if '一' <= c <= '鿿']
got = [c for c in open(sys.argv[2]).read().split("=>", 1)[-1] if '一' <= c <= '鿿']
pool = list(got); hit = 0
for c in want:
    if c in pool: pool.remove(c); hit += 1
print(f"{hit}/{len(want)}字")
EOF
}
en() { python3 -I - "$TEXT" "$1" <<'EOF'
import re, sys
want = re.findall(r"[a-z]+", sys.argv[1].lower())
got = re.findall(r"[a-z]+", open(sys.argv[2]).read().split("=>", 1)[-1].lower())
pool = list(got); hit = 0
for w in want:
    if w in pool: pool.remove(w); hit += 1
print(f"{hit}/{len(want)}en")
EOF
}
score() {  # <wav> → "N/23字 M/48en": Chinese over the phone's window (3–11 s) only, English over all
  python3 -I -c "
import wave
w=wave.open('$1'); r=w.getframerate(); w.setpos(3*r); d=w.readframes(8*r)
v=wave.open('$W/rcrop.wav','wb'); v.setnchannels(1); v.setsampwidth(2); v.setframerate(r); v.writeframes(d)"
  ./transcribe $W/rcrop.wav zh-CN > $W/rz.txt 2>/dev/null; ./transcribe $1 en-US > $W/re.txt 2>/dev/null
  echo "$(zh $W/rz.txt) $(en $W/re.txt)"
}
scene() {  # the meeting from the Mac, the phone 3 s in
  sleep 1.5
  afplay $W/far.aiff &
  python3 phone.py play $W/near.wav --at $(python3 -c "import time;print(time.time()+3)") >/dev/null
  wait
}
osascript -e "set volume output volume $VOL"
for r in $(seq $ROUNDS); do
  rm -f /tmp/cicada-aec*
  $REPO/tools/lsctl aecDump:20 >/dev/null; scene; sleep 4
  python3 gate3.py $W 80 >/dev/null
  wav $W/mic.raw $W/rmic.wav
  line="round $r: plain $(score $W/rmic.wav)"
  for t in 0 3; do
    TUNE=$t ./aec 48000 $W/ref.raw $W/mic.raw $W/rout.raw >/dev/null
    wav $W/rout.raw $W/rout.wav
    line+=" | AEC3 tune$t $(score $W/rout.wav)"
  done
  ./rec 20 $W/rvpio.wav vpio >/dev/null & scene; wait
  afconvert -f WAVE -d LEI16@16000 -c 1 $W/rvpio.wav $W/rvpio16.wav
  line+=" | VPIO $(score $W/rvpio16.wav)"
  echo $line
done
osascript -e "set volume output volume 81"
