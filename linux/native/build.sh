#!/bin/bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/out}"
mkdir -p "$out"
if [ "$(uname)" = Darwin ]; then
  /usr/bin/clang -O3 -Wall -Wextra -shared -fPIC -o "$out/libcicada-voice.dylib" "$here/voiceprint.c"
else
  ${CC:-gcc} -O3 -Wall -Wextra -shared -fPIC -pthread -o "$out/libcicada-voice-$(uname -m).so" "$here/voiceprint.c" -lm
fi
