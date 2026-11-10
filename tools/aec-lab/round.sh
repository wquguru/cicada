#!/bin/zsh
# round.sh <repo> <volume%> [shift_ms ...]: the English clip on the MacBook speakers, recorded from the
# built-in mic plain and through VPIO; AEC3 at 16 and 48 kHz on the plain recording; each transcribed
# (en-US) and scored as words of the clip that got through. Lower is better (VPIO's bar: 0).
set -e
cd "${0:A:h}"
REPO=$1; VOL=$2; shift 2
SHIFTS=(${@:-0})
W=work; mkdir -p $W
[[ -x aec ]] || zsh build-aec.sh >/dev/null
[[ -x rec ]] || swiftc -O rec.swift -o rec 2>&1 | grep error || true
[[ -x transcribe ]] || swiftc -O $REPO/tools/transcribe.swift -o transcribe 2>&1 | grep error || true
TEXT="Thanks everyone for joining. Our revenue grew twelve percent this quarter, mostly from enterprise customers in Europe. Marketing spent less than planned, and we hired four engineers. Next month we will launch the new pricing page and review the hiring plan for the second half of the year."
[[ -f $W/far.aiff ]] || say -v Samantha -o $W/far.aiff "$TEXT"
for r in 16000 48000; do [[ -f $W/far$r.wav ]] || afconvert -f WAVE -d LEI16@$r -c 1 $W/far.aiff $W/far$r.wav; done
DUR=$(afinfo $W/far.aiff | awk '/estimated duration/{print $3}')
osascript -e "set volume output volume $VOL"
score() {  # transcript file → words of TEXT heard
  python3 -I - "$TEXT" "$1" <<'EOF'
import re, sys
want = re.findall(r"[a-z]+", sys.argv[1].lower())
got = re.findall(r"[a-z]+", open(sys.argv[2]).read().split("=>", 1)[-1].lower())
pool = list(got); hit = 0
for w in want:
    if w in pool: pool.remove(w); hit += 1
print(f"{hit}/{len(want)} words through")
EOF
}
play_rec() {  # mode → $W/mic_<mode>.wav
  ./rec $(( DUR + 2.5 )) $W/mic_$1.wav $1 &
  sleep 1.2; afplay $W/far.aiff; wait
}
echo "== volume $VOL%"
[[ -n $NOREC ]] || play_rec plain
[[ -n $NOREC ]] || play_rec vpio
for m in plain vpio; do
  afconvert -f WAVE -d LEI16@16000 -c 1 $W/mic_$m.wav $W/mic_${m}16.wav
  ./transcribe $W/mic_${m}16.wav en-US > $W/t_$m.txt 2>/dev/null || true
  echo "$m: $(score $W/t_$m.txt)"
done
afconvert -f WAVE -d LEI16@48000 -c 1 $W/mic_plain.wav $W/mic_plain48.wav
for r in 16000 48000; do
  for s in $SHIFTS; do
    src=$W/mic_plain16.wav; [[ $r == 48000 ]] && src=$W/mic_plain48.wav
    python3 align.py $W/far$r.wav $src $r $W $s
    ./aec $r $W/ref.raw $W/mic.raw $W/out.raw
    afconvert -f WAVE -d LEI16@$r -c 1 --file-format WAVE $W/out.raw $W/out.wav 2>/dev/null || \
      python3 -I -c "import wave,sys; w=wave.open('$W/out.wav','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate($r); w.writeframes(open('$W/out.raw','rb').read())"
    ./transcribe $W/out.wav en-US > $W/t_aec.txt 2>/dev/null || true
    echo "aec3 ${r} Hz shift ${s} ms: $(score $W/t_aec.txt)"
  done
done
