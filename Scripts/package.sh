#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

LOCAL_ONLY=0
if [[ "${1:-}" == "--local-only" ]]; then
  LOCAL_ONLY=1
elif (( $# > 0 )); then
  print -u2 "用法：zsh Scripts/package.sh [--local-only]"
  exit 2
fi

SDK="${SDKROOT:-}"
if [[ -z "$SDK" ]]; then
  if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk ]]; then
    SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk
  else
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
  fi
fi

APP="$ROOT/dist/语音输入共享.app"
ZIP="$ROOT/dist/语音输入共享-macOS14-arm64.zip"
DMG="$ROOT/dist/语音输入共享-macOS14-arm64.dmg"
mkdir -p "$ROOT/.build/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon-liquid-micwave-v2.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Scripts/install-update.sh" "$APP/Contents/Resources/install-update.sh"

swiftc -O -parse-as-library \
  -module-name InputBridge \
  -sdk "$SDK" \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$ROOT/.build/module-cache" \
  "$ROOT"/Sources/InputBridge/*.swift \
  -o "$APP/Contents/MacOS/InputBridge"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

if (( LOCAL_ONLY )); then
  print "本机 App: $APP"
  exit 0
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    print -u2 "公证需要 SIGN_IDENTITY（Developer ID Application）。"
    exit 1
  fi
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

DMG_STAGE="$(mktemp -d "$ROOT/.build/inputbridge-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
/usr/bin/ditto "$APP" "$DMG_STAGE/语音输入共享.app"
ln -s /Applications "$DMG_STAGE/应用程序"
hdiutil create -volname "语音输入共享" -srcfolder "$DMG_STAGE" \
  -ov -format UDZO "$DMG"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

print "App: $APP"
print "自动更新包: $ZIP"
print "手动安装包: $DMG"
