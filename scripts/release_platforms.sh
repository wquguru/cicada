#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?usage: scripts/release_platforms.sh <version>}
awk -v v="$VERSION" '
  /^## / { on = ($2 == v); if (on) found = 1; next }
  on && /^### (Mac|Windows|Android|Linux)$/ { print tolower($2); n++ }
  END { if (!found) exit 1; if (!n) print "mac" }
' CHANGELOG.md || { echo "no CHANGELOG.md section for $VERSION" >&2; exit 1; }
