#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! out=$(scripts/dotnet.sh build tests/Cicada.Tests -o build/tests -v quiet -nologo 2>&1); then
  echo "$out" | grep -E ' error ' | sort -u >&2
  exit 1
fi
echo "$out" | grep -E 'warning CS' | sort -u || true
DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}" build/tests/Cicada.Tests
