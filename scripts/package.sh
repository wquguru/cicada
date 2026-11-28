#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(tr -d '[:space:]' < VERSION)

notarize() {
  [[ -n "${SIGN_IDENTITY:-}" ]] || return 0
  local auth=(--keychain-profile "${NOTARY_PROFILE:-}")
  [[ -n "${NOTARY_PROFILE:-}" ]] || auth=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  xcrun notarytool submit "$1" "${auth[@]}" --wait --timeout 2h --output-format json > build/notary.json
  grep -q '"status" *: *"Accepted"' build/notary.json || {
    cat build/notary.json >&2
    local id; id=$(sed -nE 's/.*"id" *: *"([^"]+)".*/\1/p' build/notary.json)
    [[ -n "$id" ]] && xcrun notarytool log "$id" "${auth[@]}" >&2
    exit 1
  }
}
ARCHS="${ARCH:-arm64 x86_64}"
rm -f build/Cicada-*.zip build/Cicada-*.dmg build/LiveSubs-*.zip build/LiveSubs-*.dmg build/checksums.txt
rm -rf build/dmg && mkdir -p build/dmg

for A in $ARCHS; do
  if [[ "$A" == "x86_64" ]]; then
    SUFFIX="macOS-Intel"
  else
    SUFFIX="macOS-AppleSilicon"
  fi
  NAME="Cicada-$VERSION-$SUFFIX"

  ARCH="$A" RELEASE=1 scripts/build.sh
  APP=build/Cicada.app
  ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$APP/Contents/Info.plist")
  [[ "$ID" == com.wquguru.cicada ]] || { echo "Not a release build: $ID" >&2; exit 1; }

  ditto -c -k --keepParent "$APP" "build/$NAME.zip"
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    notarize "build/$NAME.zip"
    xcrun stapler staple -q "$APP"
    rm "build/$NAME.zip" && ditto -c -k --keepParent "$APP" "build/$NAME.zip"
  fi

  if [[ ! -f build/dmg/background.tiff ]]; then
    RENDER_BIN="$APP/Contents/MacOS/Cicada"
    if [[ "$A" != "$(uname -m)" ]]; then
      swift build -c release --product Cicada
      RENDER_BIN="$(swift build -c release --show-bin-path)/Cicada"
    fi
    "$RENDER_BIN" --render-dmg-background build/dmg/background.png 1
    "$RENDER_BIN" --render-dmg-background build/dmg/background@2x.png 2
    tiffutil -cathidpicheck build/dmg/background.png build/dmg/background@2x.png -out build/dmg/background.tiff 2>/dev/null
  fi

  STAGE=build/dmg/stage
  MOUNT=build/dmg/mount
  rm -rf "$STAGE" "$MOUNT" build/dmg/rw.dmg
  mkdir -p "$STAGE/.background" "$MOUNT"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  cp build/dmg/background.tiff "$STAGE/.background/background.tiff"
  [[ -f Resources/dmg/DS_Store ]] && cp Resources/dmg/DS_Store "$STAGE/.DS_Store"
  cp "$APP/Contents/Resources/AppIcon.icns" "$STAGE/.VolumeIcon.icns"
  hdiutil create -quiet -srcfolder "$STAGE" -volname "Cicada" -fs HFS+ -format UDRW -ov build/dmg/rw.dmg
  hdiutil attach -quiet -readwrite -noverify -noautoopen -nobrowse -mountpoint "$MOUNT" build/dmg/rw.dmg
  SetFile -a C "$MOUNT" 2>/dev/null || true
  hdiutil detach -quiet "$MOUNT"
  hdiutil convert -quiet build/dmg/rw.dmg -format UDZO -imagekey zlib-level=9 -ov -o "build/$NAME.dmg"
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "build/$NAME.dmg"
    notarize "build/$NAME.dmg"
    xcrun stapler staple -q "build/$NAME.dmg"
  fi
  rm -rf "$STAGE" "$MOUNT" build/dmg/rw.dmg
done

rm -f build/notary.json
(cd build && shasum -a 256 Cicada-*.dmg Cicada-*.zip > checksums.txt)
echo "Packaged:"
ls -1 build/Cicada-*.dmg build/Cicada-*.zip build/checksums.txt
