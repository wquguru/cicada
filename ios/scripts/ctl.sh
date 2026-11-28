#!/usr/bin/env bash
set -euo pipefail
DEVICE=booted
if [[ ${1:-} == -d ]]; then DEVICE=$2; shift 2; fi
APP=com.indaloop.cicada.dev

if xcrun devicectl list devices 2>/dev/null | grep -v simulated | grep -q -- "$DEVICE"; then
    case ${1:-} in
    --log)
        tmp=$(mktemp -d)
        xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer \
            --domain-identifier "$APP" --source Library/Caches/livesubs-dev-debug.log \
            --destination "$tmp/log" >/dev/null
        tail -n "${2:-40}" "$tmp/log"; rm -rf "$tmp"; exit ;;
    --shot)
        xcrun devicectl device capture screenshot --device "$DEVICE" --destination "$2" >/dev/null; exit ;;
    esac
    for cmd in "$@"; do
        url="cicada-dev://debug?cmd=$(python3 -c 'import sys, urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$cmd")"
        xcrun devicectl device process launch --device "$DEVICE" --payload-url "$url" "$APP" >/dev/null
    done
    exit
fi

DATA=$(xcrun simctl get_app_container "$DEVICE" $APP data)
printf '%s\n' "$@" >> "$DATA/Library/Caches/debug-command"
xcrun simctl spawn "$DEVICE" notifyutil -p com.indaloop.cicada.debug
