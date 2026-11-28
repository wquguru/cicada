#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
native/build.sh >/dev/null
python3 -m unittest discover -s tests -q
python3 scripts/strings.py
python3 -m py_compile cicada/app/*.py cicada/core/*.py cli.py
echo "linux: ok"
