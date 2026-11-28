#!/usr/bin/env python3
import re, sys
from pathlib import Path

MAX_BYTES = 6 * 1024
MAX_LINE = 400
SECTIONS = ["Scope", "Hard rules", "Design", "Layout", "Commands", "Verifying", "Conventions"]

path = Path(__file__).resolve().parent.parent / "AGENTS.md"
text = path.read_text(encoding="utf-8")
errors = []
size = len(text.encode("utf-8"))
if size > MAX_BYTES:
    errors.append(f"{size} bytes, budget {MAX_BYTES}: move detail to code, tests or tools/README.md")
for n, line in enumerate(text.splitlines(), 1):
    if len(line) > MAX_LINE:
        errors.append(f"line {n} is {len(line)} chars (max {MAX_LINE})")
found = re.findall(r"^## (.+)$", text, re.M)
if found != SECTIONS:
    errors.append(f"sections {found}, expected {SECTIONS} in that order")
if "```" not in text:
    errors.append("no fenced block: keep the commands block (prevents flat-list regression)")
for e in errors:
    print(f"AGENTS.md: {e}", file=sys.stderr)
sys.exit(1 if errors else 0)
