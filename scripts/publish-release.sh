#!/usr/bin/env bash
set -euo pipefail
VERSION=${1:?usage: scripts/publish-release.sh <version, e.g. 1.0.1>}
TAG="v$VERSION"
REPO=wquguru/cicada
[[ "$(gh release view "$TAG" -R "$REPO" --json isDraft -q .isDraft)" == true ]] || { echo "$TAG is not a draft" >&2; exit 1; }
assets=$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name')
echo "$assets"
for f in checksums.txt macOS-AppleSilicon.dmg macOS-AppleSilicon.zip macOS-Intel.dmg Windows-x64.exe \
         Windows-ARM64.exe Android.apk Linux.tar.gz; do
  grep -q -- "$f\$" <<< "$assets" || { echo "$TAG has no *$f" >&2; exit 1; }
done
latest=false; grep -q '\.dmg$' <<< "$assets" && latest=true
read -r -p "Publish $TAG (latest: $latest)? [y/N] " ok
[[ "$ok" == y ]] || exit 1
gh release edit "$TAG" -R "$REPO" --draft=false --latest=$latest
echo "Published https://github.com/$REPO/releases/tag/$TAG"
