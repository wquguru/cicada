#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
KEY_FILE="$HOME/Library/Application Support/LiveSubs/ling-api-key"
[ -f "$KEY_FILE" ] || KEY_FILE="$HOME/Library/Application Support/LiveSubs Dev/ling-api-key"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

say() {
  python3 -I - "$1" "$2" "$3" "$KEY_FILE" <<'PY'
import sys, json, base64, urllib.request
out, voice, text, key_file = sys.argv[1:]
key = open(key_file).read().strip()
body = {"model": "Ming-3.0-tts-0.5B", "input": text, "voice": voice, "response_format": "pcm",
        "sample_rate": 24000, "stream": True, "stream_format": "sse",
        "instructions": "Speak fast and casually, like a colleague in a real meeting, natural rhythm."}
req = urllib.request.Request("https://api.ant-ling.com/v1/audio/speech", data=json.dumps(body).encode(),
                             headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"})
pcm = b""
with urllib.request.urlopen(req, timeout=60) as r:
    for line in r:
        line = line.decode().strip()
        if not line.startswith("data:"): continue
        try: o = json.loads(line[5:])
        except ValueError: continue
        if o.get("type") == "speech.audio.done": break
        if o.get("audio"): pcm += base64.b64decode(o["audio"])
open(out, "wb").write(pcm)
PY
}
TRIM="silenceremove=start_periods=1:start_threshold=-45dB,areverse,silenceremove=start_periods=1:start_threshold=-45dB,areverse"
PCM="-f s16le -ar 24000 -ac 1"
if [ "${1:-}" = speak ]; then
  mkdir -p site/audio
  say "$T/en.pcm" UK_Charlotte "I'll send the final draft to design today."
  say "$T/zh.pcm" 灵小棠 "我今天就把终稿发给设计。"
  for l in en zh; do
    ffmpeg -y -loglevel error $PCM -i "$T/$l.pcm" -af "$TRIM,loudnorm=I=-16:TP=-1.5,aresample=22050" -c:a aac -b:a 64k "site/audio/speak-$l.m4a"
    ffprobe -v error -show_entries format=duration -of csv=p=0 "site/audio/speak-$l.m4a"
  done
  exit 0
fi
if [ "${1:-}" = zh ]; then
  OUT=site/audio/meeting-zh.m4a
  say "$T/1.pcm" 灵小雅 "好，发布现在进展到哪了？"
  say "$T/2.pcm" 灵小锋 "嗯，我觉得三月三号能上线，只要设计周五之前确认。"
  say "$T/3.pcm" 灵小雅 "好，那就这么定了。"
else
  OUT=Resources/sample/sample.m4a
  say "$T/1.pcm" US_Emma "Okay, so where are we on the launch?"
  say "$T/2.pcm" UK_George "Uh, I think we can ship March third, if design signs off by Friday."
  say "$T/3.pcm" US_Emma "Great, let's lock that in."
fi
mkdir -p "$(dirname "$OUT")"

ffmpeg -y -loglevel error $PCM -i "$T/1.pcm" $PCM -i "$T/2.pcm" $PCM -i "$T/3.pcm" -filter_complex \
  "[0]$TRIM,adelay=250,apad=pad_dur=0.22[a];[1]$TRIM,apad=pad_dur=0.2[b];[2]$TRIM,apad=pad_dur=0.35[c];[a][b][c]concat=n=3:v=0:a=1,loudnorm=I=-16:TP=-1.5,aresample=22050" \
  -c:a aac -b:a 64k "$OUT"
ffmpeg -i "$OUT" -af silencedetect=n=-40dB:d=0.12 -f null - 2>&1 | grep -o 'silence_[a-z]*: [0-9.]*' || true
ls -la "$OUT"
