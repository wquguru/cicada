#!/bin/bash
set -euo pipefail
exec "$(dirname "$0")/cli.sh" test
