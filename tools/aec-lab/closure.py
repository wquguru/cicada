#!/usr/bin/env python3
"""Include closure of EchoCanceller3 in a webrtc-audio-processing tree: which files it needs
(headers, and the .cc next to each header), and which absl headers. Usage: closure.py <root>"""
import re, sys
from pathlib import Path

root = Path(sys.argv[1]) / "webrtc"
inc = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)
seen, absl, missing = set(), set(), set()
todo = ["modules/audio_processing/aec3/echo_canceller3.cc", "modules/audio_processing/aec3/echo_canceller3.h"]
while todo:
    rel = todo.pop()
    if rel in seen:
        continue
    p = root / rel
    if not p.exists():
        missing.add(rel)
        continue
    seen.add(rel)
    for m in inc.findall(p.read_text(errors="ignore")):
        if m.startswith("absl/"):
            absl.add(m)
        else:
            todo.append(m)
    if rel.endswith(".h"):
        for ext in (".cc", ".c"):
            cc = rel[:-2] + ext
            if (root / cc).exists():
                todo.append(cc)
lines = sum(len((root / f).read_text(errors="ignore").splitlines()) for f in seen)
dirs = {}
for f in seen:
    d = "/".join(f.split("/")[:2])
    dirs[d] = dirs.get(d, 0) + 1
print(f"files {len(seen)}, lines {lines}")
for d, n in sorted(dirs.items(), key=lambda x: -x[1]):
    print(f"  {d}: {n}")
print(f"absl headers {len(absl)}:", " ".join(sorted(absl)))
print("missing:", " ".join(sorted(missing)))
