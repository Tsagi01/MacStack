#!/bin/bash
# 生成可分发 DMG。设置 MACSTACK_DEVELOPER_ID_APPLICATION 后使用 Developer ID 签名；
# 再设置 MACSTACK_NOTARY_PROFILE 后提交 Apple 公证。未设置时只生成本地测试包。
#
# 顺序要求：**装订票据之后必须重新生成 ZIP。** 票据是写进 .app 包里的，装订前打的
# ZIP 不含票据，用户解压安装后离线校验会失败。DMG 在装订之后创建，不受影响。
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
rm -f "$DMG_PATH" "$ZIP_PATH" "$DMG_PATH.sha256" "$ZIP_PATH.sha256"

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

# 先打一个 ZIP 用于提交公证。此时 app 还没有装订票据 —— 这没关系，公证只需要
# 签名正确的包；票据是公证通过后再装订进 app 的。
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

if [ -n "${MACSTACK_NOTARY_PROFILE:-}" ]; then
  if [ -z "${MACSTACK_DEVELOPER_ID_APPLICATION:-}" ]; then
    printf 'MACSTACK_NOTARY_PROFILE requires MACSTACK_DEVELOPER_ID_APPLICATION.\n' >&2
    exit 64
  fi
  /usr/bin/xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$MACSTACK_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP_DIR"

  # 装订之后**必须重新生成 ZIP**。
  #
  # 装订票据是写进 `.app` 包里的，而上面那个 ZIP 是在装订之前打的，里面的 app
  # 不含票据 —— 用户从 ZIP 解压安装后，Gatekeeper 只能联网校验；离线时会被拒绝。
  # DMG 是在装订之后才创建的（见下），所以只有 ZIP 有这个顺序问题。
  /bin/rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"

  # 解包校验：确认交付物里那个 app 真的带票据，而不是只校验了构建缓存里的副本。
  VERIFY_DIR="$(mktemp -d)"
  /usr/bin/ditto -x -k "$ZIP_PATH" "$VERIFY_DIR"
  /usr/bin/xcrun stapler validate "$VERIFY_DIR/MacStack.app"
  /bin/rm -rf "$VERIFY_DIR"
fi

/usr/bin/hdiutil create -volname "MacStack $VERSION" -srcfolder "$APP_DIR" -ov -format UDZO "$DMG_PATH"
if [ -n "${MACSTACK_DEVELOPER_ID_APPLICATION:-}" ]; then
  /usr/bin/codesign --force --timestamp --sign "$MACSTACK_DEVELOPER_ID_APPLICATION" "$DMG_PATH"
fi
if [ -n "${MACSTACK_NOTARY_PROFILE:-}" ]; then
  /usr/bin/xcrun notarytool submit "$DMG_PATH" --keychain-profile "$MACSTACK_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$DMG_PATH"
fi

(
  cd "$RELEASE_DIR"
  /usr/bin/shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256"
  /usr/bin/shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256"
)
/usr/bin/file "$APP_DIR/Contents/MacOS/MacStack"
/usr/bin/codesign -dv --verbose=2 "$APP_DIR" 2>&1 | /usr/bin/head -12
printf 'Release: %s\nRelease: %s\nChecksums: %s, %s\n' \
  "$DMG_PATH" "$ZIP_PATH" "$DMG_PATH.sha256" "$ZIP_PATH.sha256"
