#!/bin/bash
set -euo pipefail
adb="$HOME/.cicada-android/sdk/platform-tools/adb"
pkg=com.wquguru.cicada.dev
case "${1:-state}" in
  push)
    "$adb" push "$2" /data/local/tmp/cicada-push >/dev/null
    "$adb" shell "run-as $pkg sh -c 'cat /data/local/tmp/cicada-push > files/$(basename "$2")'; rm /data/local/tmp/cicada-push"
    echo "files/$(basename "$2")"; exit 0 ;;
  key)
    f="${CICADA_KEY_FILE:-$HOME/Library/Application Support/LiveSubs Dev/ling-api-key}"
    [ -f "$f" ] || f="$HOME/Library/Application Support/LiveSubs/ling-api-key"
    "$adb" shell "run-as $pkg sh -c 'mkdir -p files && cat > files/ling-api-key && chmod 600 files/ling-api-key'" < "$f"
    set -- key reload ;;
  aikey)
    f="${CICADA_KEY_FILE:-$HOME/Library/Application Support/LiveSubs Dev/$2}"
    "$adb" shell "run-as $pkg sh -c 'cat > files/key-import'" < "$f"
    set -- key import key-import ;;
  log) exec "$adb" shell "run-as $pkg cat cache/cicada-dev-debug.log" ;;
esac
send() { "$adb" shell am broadcast -a com.wquguru.cicada.dev.DEBUG -p "$pkg" -f 0x20 --es cmd "'$*'" 2>&1; }
out=$(send "$@"); printf "%s" "$out" | grep -q "data=" || { sleep 2; out=$(send "$@"); }
data=$(printf '%s' "$out" | sed -n 's/.*data="\(.*\)"$/\1/p' | tr -d '\r')
[ -n "$data" ] && echo "$data" || { echo "$out" >&2; exit 1; }
