#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/check-agents.py
F=$(xcode-select -p)/Library/Developer/Frameworks
L=$(xcode-select -p)/Library/Developer/usr/lib
exec swift test -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L" "$@"
