#!/bin/zsh
# dt.sh [record]: double talk. "record" first records the Chinese sentence alone from the Mac speakers
# at 56 % (the near end's sound at the mic). Then for each near level: mix into the last aecDump's mic,
# AEC3 with the host-time reference +80 ms (full: suppressor on; linear: the filter's output only),
# scored as Chinese characters kept (zh-CN) and English words leaked (en-US).
cd "${0:A:h}"
W=work
NEAR="我同意这个数字。设计那个岗位很急，周四之前我会回复。"
TEXT="Thanks everyone for joining. Our revenue grew twelve percent this quarter, mostly from enterprise customers in Europe. Marketing spent less than planned, and we hired four engineers. Next month we will launch the new pricing page and review the hiring plan for the second half of the year."
if [[ $1 == record ]]; then
  [[ -f $W/near.aiff ]] || say -v Tingting -o $W/near.aiff "$NEAR"
  osascript -e "set volume output volume 56"
  ./rec 8 $W/nearmic.wav & sleep 1; afplay $W/near.aiff; wait
  osascript -e "set volume output volume 81"
  afconvert -f WAVE -d LEI16@48000 -c 1 $W/nearmic.wav $W/nearmic.s16.wav
fi
wav() {  # <raw> <wav> [rate]
  python3 -I -c "import wave; w=wave.open('$2','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(${3:-48000}); w.writeframes(open('$1','rb').read())"
}
to16() {  # work/<name>.raw (48 kHz) → work/<name>.16.raw
  wav $W/$1.raw $W/$1.48.wav
  afconvert -f WAVE -d LEI16@16000 -c 1 $W/$1.48.wav $W/$1.16.wav
  python3 -I -c "import wave; w=wave.open('$W/$1.16.wav'); open('$W/$1.16.raw','wb').write(w.readframes(w.getnframes()))"
}
zh() { python3 -I - "$NEAR" "$1" <<'EOF'
import sys
want = [c for c in sys.argv[1] if '一' <= c <= '鿿']
got = [c for c in open(sys.argv[2]).read().split("=>", 1)[-1] if '一' <= c <= '鿿']
pool = list(got); hit = 0
for c in want:
    if c in pool: pool.remove(c); hit += 1
print(f"{hit}/{len(want)} 字")
EOF
}
en() { python3 -I - "$TEXT" "$1" <<'EOF'
import re, sys
want = re.findall(r"[a-z]+", sys.argv[1].lower())
got = re.findall(r"[a-z]+", open(sys.argv[2]).read().split("=>", 1)[-1].lower())
pool = list(got); hit = 0
for w in want:
    if w in pool: pool.remove(w); hit += 1
print(f"{hit}/{len(want)} English")
EOF
}
zsh build-aec.sh >/dev/null
python3 gate3.py $W 80 >/dev/null
for g in 0 -6 -12; do
  python3 dt.py $W $g 5
  ./aec 48000 $W/ref.raw $W/dtmic.raw $W/dtout.raw >/dev/null
  wav $W/dtout.raw $W/dtout.wav
  wav $W/nearonly.raw $W/nearonly.wav
  wav $W/dtmic.raw $W/dtmic.wav
  # The linear output crashes AEC3's framer at 48 kHz: run it at 16 kHz (its output rate anyway).
  to16 ref; to16 dtmic
  LINEAR=1 ./aec 16000 $W/ref.16.raw $W/dtmic.16.raw $W/dt16.raw >/dev/null
  wav $W/dt16.raw.lin16.raw $W/dtlin.wav 16000
  for f in nearonly dtmic dtout dtlin; do
    ./transcribe $W/$f.wav zh-CN > $W/z_$f.txt 2>/dev/null
    ./transcribe $W/$f.wav en-US > $W/e_$f.txt 2>/dev/null
  done
  echo "near ${g} dB: alone $(zh $W/z_nearonly.txt) | mic $(zh $W/z_dtmic.txt), $(en $W/e_dtmic.txt) | full $(zh $W/z_dtout.txt), $(en $W/e_dtout.txt) | linear $(zh $W/z_dtlin.txt), $(en $W/e_dtlin.txt)"
  echo "   linear: $(cat $W/z_dtlin.txt) / $(cat $W/e_dtlin.txt)"
done
