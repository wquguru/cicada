#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ "${DEVICE:-}" == 1 ]]; then
  SDK=iphoneos
  TARGET=arm64-apple-ios26.0
  APP=ios/build/device/Cicada.app
  PLATFORM=iPhoneOS
else
  SDK=iphonesimulator
  TARGET=arm64-apple-ios26.0-simulator
  APP=ios/build/Cicada.app
  PLATFORM=iPhoneSimulator
fi
rm -rf "$APP"
mkdir -p "$APP"

files=()
while IFS= read -r line; do [[ -z $line || $line == \#* ]] || files+=("$line"); done < ios/shared-sources.txt
while IFS= read -r f; do files+=("$f"); done < <(find ios/Sources -name '*.swift' | sort)

SDKPATH=$(xcrun --show-sdk-path --sdk "$SDK")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
printf '%s' '["AppIntent","AppEntity","TransientAppEntity","AppEnum","EntityQuery","AppShortcutsProvider","AppShortcutProviding","DynamicOptionsProvider","LiveActivityIntent","ControlConfigurationIntent","WidgetConfigurationIntent","_IntentValueRepresentable","AppIntentsPackage"]' > "$WORK/protocols.json"
CONST=(-wmo -Xfrontend -const-gather-protocols-file -Xfrontend "$WORK/protocols.json")
intents_metadata() {
  local module=$1 out=$2 binary=$3; shift 3
  printf '%s\n' "$@" > "$WORK/$module.sources"
  printf '%s\n' "$WORK/$module.swiftconstvalues" > "$WORK/$module.constvals"
  xcrun appintentsmetadataprocessor --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun -f swiftc)")")")" \
    --module-name "$module" --sdk-root "$SDKPATH" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
    --platform-family iOS --deployment-target 26.0 --target-triple "$TARGET" --output "$out" \
    --source-file-list "$WORK/$module.sources" --swift-const-vals-list "$WORK/$module.constvals" \
    --binary-file "$binary" --deployment-aware-processing --no-app-shortcuts-localization --force --quiet-warnings >/dev/null 2>&1
  [[ -d "$out/Metadata.appintents" ]] || { echo "no App Intents metadata for $module"; exit 1; }
}

extra=()
[[ -n "${STRINGS_OUT:-}" ]] && extra=(-emit-localized-strings -emit-localized-strings-path "$STRINGS_OUT")
xcrun --sdk "$SDK" swiftc -O -swift-version 5 -parse-as-library -module-name Cicada \
  -target "$TARGET" -sdk "$SDKPATH" -D CICADA_IOS "${CONST[@]}" -emit-const-values-path "$WORK/Cicada.swiftconstvalues" \
  "${extra[@]+"${extra[@]}"}" "${files[@]}" -o "$APP/Cicada"
intents_metadata Cicada "$APP" "$APP/Cicada" "${files[@]}"

cp ios/Resources/Info.plist "$APP/Info.plist"
cp ios/Resources/PrivacyInfo.xcprivacy "$APP/"
ICON_TOOL=.build/release/CicadaIcon
[[ -x $ICON_TOOL ]] || swift build -c release --product CicadaIcon >/dev/null
mkdir -p "$WORK/Assets.xcassets/AppIcon.appiconset"
"$ICON_TOOL" --ios "$WORK/Assets.xcassets/AppIcon.appiconset/icon.png" $([[ "${RELEASE:-}" == 1 ]] || echo --dev)
printf '%s' '{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}' \
  > "$WORK/Assets.xcassets/AppIcon.appiconset/Contents.json"
printf '%s' '{"info":{"author":"xcode","version":1}}' > "$WORK/Assets.xcassets/Contents.json"
xcrun actool "$WORK/Assets.xcassets" --compile "$APP" --platform "$SDK" --minimum-deployment-target 26.0 \
  --app-icon AppIcon --target-device iphone --target-device ipad \
  --output-partial-info-plist "$WORK/assets.plist" --output-format human-readable-text >/dev/null
/usr/libexec/PlistBuddy -c "Merge $WORK/assets.plist" "$APP/Info.plist" >/dev/null
for d in Resources/*.lproj; do
  mkdir -p "$APP/$(basename "$d")"
  cp "$d/Localizable.strings" "$APP/$(basename "$d")/" 2>/dev/null || true
done
cp -R "$APP/zh-Hans.lproj" "$APP/zh-Hant.lproj"
cp Resources/sample/sample.m4a "$APP/"
cp -R Resources/models/SpeakerEmbedding.mlpackage "$APP/"
ICONS=$(mktemp -d)
"$ICON_TOOL" "$ICONS/logo.iconset" >/dev/null
cp "$ICONS/logo.iconset/icon_128x128@2x.png" "$APP/logo.png"
rm -rf "$ICONS"

APPEX="$APP/PlugIns/CicadaLive.appex"
mkdir -p "$APPEX"
LIVE=(ios/LiveActivity/*.swift ios/Sources/Cicada/ListenActivity.swift ios/Sources/Cicada/Intents.swift)
xcrun --sdk "$SDK" swiftc -O -swift-version 5 -parse-as-library -application-extension -module-name CicadaLive \
  -target "$TARGET" -sdk "$SDKPATH" -D CICADA_LIVE "${CONST[@]}" -emit-const-values-path "$WORK/CicadaLive.swiftconstvalues" \
  -Xlinker -e -Xlinker _NSExtensionMain \
  "${LIVE[@]}" -o "$APPEX/CicadaLive"
intents_metadata CicadaLive "$APPEX" "$APPEX/CicadaLive" "${LIVE[@]}"
cp ios/LiveActivity/Info.plist "$APPEX/Info.plist"
cp "$APP/logo.png" "$APPEX/"
for d in "$APP"/*.lproj; do cp -R "$d" "$APPEX/"; done

PLIST="$APP/Info.plist"
BUILD=${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}
for p in "$PLIST" "$APPEX/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(tr -d '[:space:]' < VERSION)" \
    -c "Set :CFBundleVersion $BUILD" -c "Set :CFBundleSupportedPlatforms:0 $PLATFORM" "$p"
done
SDKVER=$(xcrun --sdk "$SDK" --show-sdk-version)
SDKBUILD=$(xcrun --sdk "$SDK" --show-sdk-build-version)
XCBUILD=$(xcodebuild -version | awk '/Build version/{print $3}')
XCVER=$(xcodebuild -version | awk '/^Xcode/{split($2,v,"."); printf "%d%d%d0", v[1], v[2], v[3]}')
for p in "$PLIST" "$APPEX/Info.plist"; do
  /usr/libexec/PlistBuddy -c "Add :DTPlatformName string $SDK" -c "Add :DTPlatformVersion string $SDKVER" \
    -c "Add :DTPlatformBuild string $SDKBUILD" -c "Add :DTSDKName string $SDK$SDKVER" -c "Add :DTSDKBuild string $SDKBUILD" \
    -c "Add :DTXcode string $XCVER" -c "Add :DTXcodeBuild string $XCBUILD" \
    -c "Add :DTCompiler string com.apple.compilers.llvm.clang.1_0" -c "Add :BuildMachineOSBuild string $(sw_vers -buildVersion)" "$p"
done
if [[ "${RELEASE:-}" != 1 ]]; then
  STAMP="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo local) @ $(git rev-parse --short HEAD 2>/dev/null || echo none)"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.indaloop.cicada.dev" \
    -c "Set :CFBundleName Cicada Dev" -c "Set :CFBundleDisplayName Cicada Dev" \
    -c "Add :LiveSubsDev string $STAMP" \
    -c "Set :BGTaskSchedulerPermittedIdentifiers:0 com.indaloop.cicada.dev.import" \
    -c "Add :CFBundleURLTypes array" -c "Add :CFBundleURLTypes:0 dict" \
    -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string cicada-dev" \
    "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.indaloop.cicada.dev.live" "$APPEX/Info.plist"
fi
if [[ "${DEVICE:-}" != 1 ]]; then
  codesign --force --sign - "$APPEX" 2>/dev/null
  codesign --force --sign - "$APP" 2>/dev/null
else
  : "${SIGN_IDENTITY:?DEVICE=1 needs SIGN_IDENTITY (and PROFILE, PROFILE_LIVE): see ios/scripts/provision.sh}"
  sign() {
    cp "$2" "$1/embedded.mobileprovision"
    security cms -D -i "$2" > "$WORK/profile.plist"
    /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORK/profile.plist" > "$WORK/entitlements.plist"
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "$WORK/entitlements.plist" --generate-entitlement-der "$1"
  }
  sign "$APPEX" "${PROFILE_LIVE:?}"
  sign "$APP" "${PROFILE:?}"
  codesign --verify --deep --strict "$APP"
fi
echo "Built $APP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST") $(tr -d '[:space:]' < VERSION) ($BUILD))"
