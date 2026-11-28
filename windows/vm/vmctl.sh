#!/bin/bash
set -euo pipefail
VM="${VM:-$HOME/VMs/cicada-win11}"
common=(-i "$VM/vm_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5)
mon() { printf '%s\n' "$*" | nc -U -w 2 "$VM/monitor.sock" >/dev/null; }
case "$1" in
  shot)
    tmp="$VM/shot.ppm"; rm -f "$tmp"; mon "screendump $tmp"
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$tmp" ] && break; sleep 0.3; done
    sleep 0.3; sips -s format png "$tmp" --out "$2" >/dev/null ;;
  mon) shift; mon "$*" ;;
  ssh) shift; ssh "${common[@]}" -p 2222 tester@127.0.0.1 "[Console]::OutputEncoding = [Text.Encoding]::UTF8; $*" ;;
  g) shift; "$0" ssh "& C:\\cicada-test\\guest.ps1 $*" ;;
  run)
    "$0" put "$2" C:/cicada-test/run.ps1 && "$0" g desk "'& C:\\cicada-test\\run.ps1'" ;;
  put) scp -r "${common[@]}" -P 2222 "$2" "tester@127.0.0.1:$3" ;;
  stop)
    pid=$(cat "$VM/qemu.pid" 2>/dev/null) && kill -0 "$pid" 2>/dev/null || { echo "not running"; exit 0; }
    mon system_powerdown || true
    for _ in $(seq 60); do kill -0 "$pid" 2>/dev/null || { echo "stopped"; exit 0; }; sleep 2; done
    mon quit || true; echo "forced off after 2 min" ;;
  *) echo "usage: vmctl.sh shot|mon|ssh|put|run|g|stop" >&2; exit 2 ;;
esac
