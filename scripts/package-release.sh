#!/bin/bash
# 生成可分发 DMG。设置 MACSTACK_DEVELOPER_ID_APPLICATION 后使用 Developer ID 签名；
# 再设置 MACSTACK_NOTARY_PROFILE 后提交 Apple 公证。未设置时只生成本地测试包。
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/swift-env.sh"
bash "$PROJECT_DIR/scripts/build-app.sh"

APP_DIR="$BUILD_CACHE/Packaging/MacStack.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
RELEASE_DIR="$PROJECT_DIR/dist/releases"
DMG_PATH="$RELEASE_DIR/MacStack-$VERSION-arm64.dmg"
ZIP_PATH="$RELEASE_DIR/MacStack-$VERSION-arm64.zip"
mkdir -p "$RELEASE_DIR"
rm -f "$DMG_PATH" "$ZIP_PATH" "$DMG_PATH.sha256"

if [ -n "${MACSTACK_DEVELOPER_ID_APPLICATION:-}" ]; then
  RUNTIME_DIR="$APP_DIR/Contents/Resources/runtime"
  if [ -d "$RUNTIME_DIR" ]; then
    find "$RUNTIME_DIR" -type f -print | while IFS= read -r item; do
      if /usr/bin/file -b "$item" | /usr/bin/grep -q 'Mach-O'; then
        /usr/bin/codesign --force --options runtime --timestamp \
          --sign "$MACSTACK_DEVELOPER_ID_APPLICATION" "$item"
      fi
    done
  fi
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$MACSTACK_DEVELOPER_ID_APPLICATION" "$APP_DIR/Contents/MacOS/MacStack"
  /usr/bin/codesign --force --options runtime --timestamp \
    --sign "$MACSTACK_DEVELOPER_ID_APPLICATION" "$APP_DIR"
  /usr/bin/codesign --verify --deep --strict "$APP_DIR"
fi

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

if [ -n "${MACSTACK_NOTARY_PROFILE:-}" ]; then
  if [ -z "${MACSTACK_DEVELOPER_ID_APPLICATION:-}" ]; then
    printf 'MACSTACK_NOTARY_PROFILE requires MACSTACK_DEVELOPER_ID_APPLICATION.\n' >&2
    exit 64
  fi
  /usr/bin/xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$MACSTACK_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP_DIR"
fi

/usr/bin/hdiutil create -volname "MacStack $VERSION" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"
if [ -n "${MACSTACK_DEVELOPER_ID_APPLICATION:-}" ]; then
  /usr/bin/codesign --force --timestamp --sign "$MACSTACK_DEVELOPER_ID_APPLICATION" "$DMG_PATH"
fi
if [ -n "${MACSTACK_NOTARY_PROFILE:-}" ]; then
  /usr/bin/xcrun notarytool submit "$DMG_PATH" --keychain-profile "$MACSTACK_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$DMG_PATH"
fi

/usr/bin/shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"
/usr/bin/file "$APP_DIR/Contents/MacOS/MacStack"
/usr/bin/codesign -dv --verbose=2 "$APP_DIR" 2>&1 | /usr/bin/head -12
printf 'Release: %s\nChecksum: %s\n' "$DMG_PATH" "$DMG_PATH.sha256"
