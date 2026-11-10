#!/bin/zsh
# gate3.sh <repo> <volume%>: the English clip on the speakers while the dev build dumps its tap and mic
# (aecDump); AEC3 offline with the reference lined up by host time only. Scored as English words through.
cd "${0:A:h}"
REPO=$1; VOL=$2; W=work
TEXT="Thanks everyone for joining. Our revenue grew twelve percent this quarter, mostly from enterprise customers in Europe. Marketing spent less than planned, and we hired four engineers. Next month we will launch the new pricing page and review the hiring plan for the second half of the year."
osascript -e "set volume output volume $VOL"
rm -f /tmp/cicada-aec*
$REPO/tools/lsctl aecDump:20 >/dev/null
sleep 1.5; afplay $W/far.aiff
sleep 4
cat /tmp/cicada-aec.json; echo
score() {
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
for extra in 0 -40 -100; do
  python3 gate3.py $W $extra
  ./aec 48000 $W/ref.raw $W/mic.raw $W/out.raw
  python3 -I -c "import wave; w=wave.open('$W/out3.wav','wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000); w.writeframes(open('$W/out.raw','rb').read())"
  ./transcribe $W/out3.wav en-US > $W/t3.txt 2>/dev/null
  echo "aec3, host-time aligned, extra lead $extra ms: $(score $W/t3.txt)"
done
afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/cicada-aec-mic.wav $W/m3.wav
./transcribe $W/m3.wav en-US > $W/t3m.txt 2>/dev/null
echo "plain mic: $(score $W/t3m.txt)"
osascript -e "set volume output volume 81"
