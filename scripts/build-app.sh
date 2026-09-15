#!/bin/bash
# 本地开发打包，不安装到 /Applications，也不包含服务器组件。
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_DIR/scripts/swift-env.sh"
cd "$PROJECT_DIR"
swift build --scratch-path "$BUILD_CACHE" -c release --arch arm64
BIN_DIR="$(swift build --scratch-path "$BUILD_CACHE" -c release --arch arm64 --show-bin-path)"
APP_DIR="$BUILD_CACHE/Packaging/MacStack.app"
OUTPUT_APP_DIR="$PROJECT_DIR/dist/MacStack.app"
/bin/rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# 构建缓存和 dist 会包含可运行的 .app 副本；阻止 Spotlight 把它们显示成
# 多个已安装的 MacStack。真正给用户使用的应用仍位于 Applications。
/usr/bin/touch "$(dirname "$APP_DIR")/.metadata_never_index"
cp "$BIN_DIR/MacStack" "$APP_DIR/Contents/MacOS/MacStack"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/MacStack.icns" "$APP_DIR/Contents/Resources/MacStack.icns"
RUNTIME_STAGE="${MACSTACK_RUNTIME_STAGE:-$PROJECT_DIR/runtime/stage}"
if [ -f "$RUNTIME_STAGE/manifest.json" ]; then
  bash "$PROJECT_DIR/scripts/verify-portable-runtime.sh" "$RUNTIME_STAGE"
  /usr/bin/ditto "$RUNTIME_STAGE" "$APP_DIR/Contents/Resources/runtime"
  printf 'Embedded portable runtime: %s\n' "$RUNTIME_STAGE"
else
  printf 'Portable runtime stage not found; building Homebrew-backed development app.\n'
fi
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
# Documents 的文件提供器可能在包刚生成时再次添加 FinderInfo。只重试清理
# 当前构建产物的元数据，不触碰源码和其他应用的扩展属性。
SIGNED=0
for _ in 1 2 3 4 5; do
  # This is a generated build artifact. Strip all extended metadata copied
  # from bottles or re-added by the Documents file provider before signing.
  /usr/bin/xattr -cr "$APP_DIR" 2>/dev/null || true
  # ad-hoc 签名仅供本机运行，不等于 Developer ID 签名或公证。
  if /usr/bin/codesign --force --sign - "$APP_DIR" && /usr/bin/codesign --verify --deep --strict "$APP_DIR"; then
    SIGNED=1
    break
  fi
  sleep 0.2
done
if [ "$SIGNED" -ne 1 ]; then
  printf 'Unable to sign generated app after clearing file-provider metadata.\n' >&2
  exit 1
fi
/usr/bin/file "$APP_DIR/Contents/MacOS/MacStack"
mkdir -p "$PROJECT_DIR/dist"
/usr/bin/touch "$PROJECT_DIR/dist/.metadata_never_index"
/bin/rm -rf "$OUTPUT_APP_DIR"
# Documents-backed folders can add Finder/file-provider xattrs after signing.
# Keep the signed development app in the cache and expose a stable symlink in
# dist; release ZIP/DMG packaging also reads the cache copy directly.
/bin/ln -s "$APP_DIR" "$OUTPUT_APP_DIR"
/usr/bin/codesign --verify --deep --strict "$OUTPUT_APP_DIR"
printf 'Built: %s\n' "$OUTPUT_APP_DIR"
