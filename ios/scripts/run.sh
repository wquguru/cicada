#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
DEVICE=${1:-"iPhone 18 Pro"}; shift || true
ID=com.indaloop.cicada.dev

xcrun simctl boot "$DEVICE" 2>/dev/null || true
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl terminate "$DEVICE" "$ID" 2>/dev/null || true
xcrun simctl install "$DEVICE" ios/build/Cicada.app
if [[ "${1:-}" == --seed ]]; then
  shift
  DATA=$(xcrun simctl get_app_container "$DEVICE" "$ID" data)
  mkdir -p "$DATA/Library/Application Support/LiveSubs Dev/Sessions"
  for s in "$@"; do cp -R "$s" "$DATA/Library/Application Support/LiveSubs Dev/Sessions/"; done
fi
xcrun simctl launch "$DEVICE" "$ID" >/dev/null
echo "Running on $DEVICE; log: $(xcrun simctl get_app_container "$DEVICE" "$ID" data)/Library/Caches/livesubs-dev-debug.log"
