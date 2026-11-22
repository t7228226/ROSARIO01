#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
  echo '需要具備 Xcode 的 macOS 建置環境。' >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version

scratch="$(mktemp -d "${TMPDIR:-/tmp}/mes-iphone.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
products="$scratch/Products"
xcodebuild -project MES.xcodeproj -scheme MES -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$scratch/DerivedData" \
  CONFIGURATION_BUILD_DIR="$products" CODE_SIGNING_ALLOWED=NO build

app="$products/MES.app"
info="$app/Info.plist"
[[ "$( /usr/libexec/PlistBuddy -c 'Print :CFBundleSupportedPlatforms:0' "$info" )" == iPhoneOS ]]
[[ "$( /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info" )" == 0.5.9 ]]
[[ "$( /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info" )" == 3 ]]
[[ -f "$app/WebAssets/index.html" && -f "$app/WebAssets/ios-bridge.js" && -f "$app/WebAssets/bom-photo.js" ]]
[[ ! -e "$app/embedded.mobileprovision" ]]
xcrun lipo "$app/MES" -verify_arch arm64

mkdir -p "$scratch/Payload" "$root/build/unsigned"
ditto "$app" "$scratch/Payload/MES.app"
name=MES_iOS_v0.5.9_Unsigned.ipa
ditto -c -k --keepParent "$scratch/Payload" "$scratch/$name"
unzip -tq "$scratch/$name"
mv -f "$scratch/$name" "$root/build/unsigned/$name"
cd "$root/build/unsigned"
shasum -a 256 "$name" > "$name.sha256"
