#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARCH="${ARCH:-$(uname -m)}"
swift build -c release --arch "$ARCH" --product Cicada
swift build -c release --product CicadaIcon
BIN=$(swift build -c release --arch "$ARCH" --show-bin-path)
HOST_BIN=$(swift build -c release --show-bin-path)

APP=build/Cicada.app
ICONSET=build/AppIcon.iconset
rm -rf "$APP" "$ICONSET" build/LiveSubs.app
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/Cicada" "$APP/Contents/MacOS/Cicada"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/sample/sample.m4a "$APP/Contents/Resources/"
cp -R Resources/models/SpeakerEmbedding.mlpackage "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp -R Resources/zh-Hans.lproj "$APP/Contents/Resources/zh-Hant.lproj"

PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(tr -d '[:space:]' < VERSION)" "$PLIST"
if [[ "${RELEASE:-}" != 1 ]]; then
  STAMP="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local) @ $(git rev-parse --short HEAD 2>/dev/null || echo none)"
  [[ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]] && STAMP+="+"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.wquguru.cicada.dev" \
    -c "Set :CFBundleName Cicada Dev" -c "Set :CFBundleDisplayName Cicada Dev" \
    -c "Add :LiveSubsDev string $STAMP" "$PLIST"
  sed -i '' -E 's/^(CFBundle(Display)?Name = ")([^"]*)";/\1\3 Dev";/' \
    "$APP"/Contents/Resources/*.lproj/InfoPlist.strings
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"
fi

ICON_FLAGS=()
[[ "${RELEASE:-}" == 1 ]] || ICON_FLAGS=(--dev)
"$HOST_BIN/CicadaIcon" ${ICON_FLAGS[@]+"${ICON_FLAGS[@]}"} "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

ID=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$PLIST")
SIGN_FLAGS=(--sign -)
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  SIGN_FLAGS=(--sign "$SIGN_IDENTITY" --options runtime --timestamp --entitlements Resources/Cicada.entitlements)
fi
codesign --force "${SIGN_FLAGS[@]}" --requirements "=designated => identifier \"$ID\"" "$APP" >/dev/null
echo "Built $APP ($ID, signed by ${SIGN_IDENTITY:-ad hoc})"
