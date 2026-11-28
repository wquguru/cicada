#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
ENV=~/.cicada-signing/ios-development.env
[[ -f $ENV ]] || { echo "no $ENV: ios/tools/provision.py development > $ENV"; exit 1; }
# shellcheck disable=SC1090
source "$ENV"
DEVICE=1 ios/scripts/build.sh
TARGET=${1:-$(xcrun devicectl list devices | grep -E 'available \(paired\)|connected' | grep -v simulated | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}
[[ -n $TARGET ]] || { echo "no iPhone or iPad connected"; exit 1; }
xcrun devicectl device install app --device "$TARGET" ios/build/device/Cicada.app
xcrun devicectl device process launch --device "$TARGET" com.indaloop.cicada.dev
