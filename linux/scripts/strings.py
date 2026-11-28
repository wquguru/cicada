#!/usr/bin/env python3
import pathlib
import re
import sys

here = pathlib.Path(__file__).resolve().parent.parent
root = here.parent
keys = []
for f in sorted((here / "cicada").rglob("*.py")):
    for k in re.findall(r'\bLF?\("((?:[^"\\]|\\.)*)"', f.read_text(encoding="utf-8")):
        if k not in keys:
            keys.append(k)


def table(path):
    if not path.exists():
        return {}
    return dict(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', path.read_text(encoding="utf-8"), re.M))


missing_any = False
for lang in ["en", "ja", "ko"]:
    mine = here / f"strings/{lang}.lproj/Linux.strings"
    have = {**table(root / f"Resources/{lang}.lproj/Localizable.strings"), **table(mine)}
    missing = [k for k in keys if k not in have]
    if missing:
        missing_any = True
        print(f"{lang}: {len(missing)} missing")
        for k in missing:
            print(f"  {k}")
        if "--write" in sys.argv:
            mine.parent.mkdir(parents=True, exist_ok=True)
            new = not mine.exists()
            with mine.open("a", encoding="utf-8") as f:
                if new:
                    f.write("/* Linux-only UI text; the Mac's Localizable.strings covers the rest. Check: linux/scripts/strings.py */\n")
                for k in missing:
                    f.write(f'"{k}" = "{k}"; /* TODO */\n')
    unused = [k for k in table(mine) if k not in keys]
    if unused:
        missing_any = True
        print(f"{lang}: {len(unused)} unused in Linux.strings")
        for k in unused:
            print(f"  {k}")
sys.exit(1 if missing_any else 0)
