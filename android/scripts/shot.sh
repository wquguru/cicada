#!/bin/bash
set -euo pipefail
out="${1:-$(dirname "$0")/../build/shot.png}"
"$HOME/.cicada-android/sdk/platform-tools/adb" exec-out screencap -p > "$out"
sips -Z "${SHOT_SIZE:-900}" "$out" >/dev/null
echo "$out"
