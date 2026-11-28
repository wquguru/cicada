#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT=ios/build/host-recognizer
mkdir -p ios/build
xcrun --sdk macosx swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos26.0 \
  Sources/Cicada/Recognition.swift Sources/Cicada/Languages.swift Sources/Cicada/AudioFiles.swift \
  ios/tools/host-recognizer/main.swift ios/tools/host-recognizer/CloudStubs.swift -o "$OUT"
if [[ $# -eq 0 ]]; then
  ids=($(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}'))
else
  ids=(); for d in "$@"; do ids+=($(xcrun simctl list devices | grep -F "$d (" | grep -oE '[0-9A-F-]{36}' | head -1)); done
fi
exec "$OUT" "${ids[@]}"
