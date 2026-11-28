#!/bin/bash
bin="$(cd "$(dirname "$0")" && pwd)"
pkill -f "focus_probe[.]py" ; pkill -f "python3 -m cicada[.]app"; sleep 1
rm -f /tmp/focus-probe.log
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.config/cicada-dev/settings.json")
s = json.load(open(p)) if os.path.exists(p) else {}
s.update(onboarded=True, view="notes")
open(p, "w").write(json.dumps(s))
PY
setsid -f python3 "$bin/focus_probe.py" >/dev/null 2>&1 </dev/null; sleep 2
setsid -f "$bin/cicada" --dev >/tmp/cicada-app.out 2>&1 </dev/null; sleep 4
"$bin/cicadactl" show notes; sleep 1
geo="$("$bin/cicadactl" windows)"; echo "$geo"
read -r x y w <<<"$(python3 -c 'import json,sys; n=json.loads(sys.argv[1])["notes"]; print(n["x"], n["y"], n["w"])' "$geo")"
sudo python3 "$bin/click.py" $((x + w / 2)) $((y + 340)); sleep 0.5
sudo python3 "$bin/click.py" $((x + w - 112)) $((y + 34)); sleep 1.5
"$bin/cicadactl" state | python3 -c 'import json,sys; print("view:", json.load(sys.stdin)["view"])'
"$bin/cicadactl" view notes >/dev/null; sleep 1
before="$("$bin/cicadactl" windows | python3 -c 'import json,sys; n=json.load(sys.stdin)["notes"]; print(n["x"], n["y"])')"
read -r x y <<<"$before"
sudo python3 "$bin/click.py" $((x + 200)) $((y + 300)) --to $((x - 400)) $((y + 350)); sleep 1
echo "drag: $before -> $("$bin/cicadactl" windows | python3 -c 'import json,sys; n=json.load(sys.stdin)["notes"]; print(n["x"], n["y"])')"
