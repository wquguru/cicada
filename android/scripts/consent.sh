#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TAP_EXACT=1 ./tap.sh "Start now" "Share screen" "Start" "立即开始" "共享屏幕" "开始" "Next" "下一步"
sleep 1
TAP_EXACT=1 ./tap.sh "Start now" "Share screen" "立即开始" "共享屏幕" 2>/dev/null || true
echo consented
