#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/gradle.sh :cli:installDist >/dev/null
props="-Dcicada.resources=$PWD/../Resources -Dcicada.androidStrings=$PWD/app/src/main/strings -Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8"
p="${https_proxy:-${HTTPS_PROXY:-}}"
if [ -n "$p" ]; then p="${p#*://}"; p="${p%/}"; props="$props -Dhttps.proxyHost=${p%:*} -Dhttps.proxyPort=${p##*:}"; fi
JAVA_HOME="$HOME/.cicada-android/jdk/Contents/Home" JAVA_OPTS="$props" exec cli/build/install/cicada-cli/bin/cicada-cli "$@"
