#!/bin/bash
# Build-machine tool: stages the ARM64 server payload used by MacStack.app.
# Homebrew is only a reproducible source for this first runtime pipeline; the
# generated payload must not retain Homebrew dylib references.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BREW="${MACSTACK_BREW:-/opt/homebrew/bin/brew}"
FINAL_STAGE="${MACSTACK_RUNTIME_STAGE:-$PROJECT_DIR/runtime/stage}"
BUILD_ROOT="$PROJECT_DIR/runtime/build"
mkdir -p "$BUILD_ROOT"
WORK="$(mktemp -d "$BUILD_ROOT/stage.XXXXXX")"
MACHO_LIST="$WORK/.macho-files"
NEW_MACHO="$WORK/.new-macho-files"
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'portable-runtime: %s\n' "$1" >&2
  exit 1
}

[ -x "$BREW" ] || fail "missing build dependency: $BREW"
for tool in /usr/bin/ditto /usr/bin/file /usr/bin/otool /usr/bin/install_name_tool /usr/bin/codesign; do
  [ -x "$tool" ] || fail "missing tool: $tool"
done

HTTPD_PREFIX="$($BREW --prefix httpd)"
PHP_PREFIX="$($BREW --prefix php@8.2)"
MARIADB_PREFIX="$($BREW --prefix mariadb@11.4)"
PHPMYADMIN_PREFIX="$($BREW --prefix phpmyadmin)"

printf 'Staging Apache from %s\n' "$HTTPD_PREFIX"
/usr/bin/ditto "$HTTPD_PREFIX" "$WORK/apache"
printf 'Staging PHP from %s\n' "$PHP_PREFIX"
/usr/bin/ditto "$PHP_PREFIX" "$WORK/php"
printf 'Staging MariaDB from %s\n' "$MARIADB_PREFIX"
/usr/bin/ditto "$MARIADB_PREFIX" "$WORK/mariadb"
printf 'Staging phpMyAdmin from %s\n' "$PHPMYADMIN_PREFIX"
/usr/bin/ditto "$PHPMYADMIN_PREFIX/share/phpmyadmin" "$WORK/phpmyadmin"
/usr/bin/ditto "$PROJECT_DIR/runtime/manifest.template.json" "$WORK/manifest.json"
mkdir -p "$WORK/lib" "$WORK/licenses"

# Bottle convenience links can point outside the keg (for example /etc init
# scripts or Homebrew's global phpMyAdmin config). MacStack supplies its own
# configuration, so dangling external links must not enter the app bundle.
find "$WORK" -type l -print | while IFS= read -r item; do
  if [ ! -e "$item" ]; then /bin/unlink "$item"; fi
done

# httpd 的 mime.types 在 bottle 里位于 .bottle/etc/httpd/。搬到稳定路径，让生成的
# Apache 配置通过 TypesConfig 引用运行时自带的副本，而不是写死系统的
# /etc/apache2/mime.types —— 后者与「核心运行时不依赖系统组件」的定位矛盾，
# 在没有系统 Apache 的机器上还会直接失败。
if [ -f "$WORK/apache/.bottle/etc/httpd/mime.types" ]; then
  mkdir -p "$WORK/apache/etc/httpd"
  /usr/bin/ditto "$WORK/apache/.bottle/etc/httpd/mime.types" "$WORK/apache/etc/httpd/mime.types"
fi

# 收集第三方许可证与声明文件。
#
# 逻辑放在独立脚本里，便于单独运行和验证。它处理了三个之前导致 licenses/ 全空的
# 问题：brew --prefix 的 opt 符号链接、匹配模式漏掉 COPYRIGHT、深度限制过浅。
# 取不到正文的组件会让构建失败并列出清单，不静默留空。
bash "$PROJECT_DIR/scripts/collect-runtime-licenses.sh" "$WORK" "$BREW"

# 移除 Homebrew 打包元数据。这些文件没有分发价值，还会带出构建机的安装信息：
#   INSTALL_RECEIPT.json —— 安装时间、构建机版本、变更文件清单
#   .brew/               —— 公式源码
#   .bottle/             —— bottle 的配置副本（mime.types 已搬到稳定路径）
#   sbom.spdx.json       —— 已由许可证收集归集到 licenses/sbom/
for component in apache php mariadb; do
  [ -d "$WORK/$component" ] || continue
  /bin/rm -rf "$WORK/$component/.brew" "$WORK/$component/.bottle"
  /bin/rm -f "$WORK/$component/INSTALL_RECEIPT.json" "$WORK/$component/sbom.spdx.json"
done

is_macho() {
  /usr/bin/file -b "$1" | /usr/bin/grep -q 'Mach-O'
}

: > "$MACHO_LIST"
find "$WORK/apache" "$WORK/php" "$WORK/mariadb" -type f -print | while IFS= read -r item; do
  if is_macho "$item"; then printf '%s\n' "$item" >> "$MACHO_LIST"; fi
done
/usr/bin/sort -u "$MACHO_LIST" -o "$MACHO_LIST"

# Recursively flatten non-system dylibs into runtime/lib. A collision is only
# accepted when the bytes are identical, so two incompatible ABIs cannot be
# silently hidden behind one basename.
while :; do
  : > "$NEW_MACHO"
  while IFS= read -r item; do
    /usr/bin/otool -L "$item" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}' | while IFS= read -r dependency; do
      case "$dependency" in
        /opt/homebrew/*|/usr/local/*)
          [ -e "$dependency" ] || fail "unresolved dependency $dependency used by $item"
          real_dependency="$(/bin/realpath "$dependency")"
          destination="$WORK/lib/$(basename "$real_dependency")"
          if [ -e "$destination" ]; then
            /usr/bin/cmp -s "$real_dependency" "$destination" || \
              fail "dylib basename collision: $real_dependency and $destination"
          else
            /usr/bin/ditto "$real_dependency" "$destination"
            printf '%s\n' "$destination" >> "$NEW_MACHO"
          fi
          ;;
      esac
    done
  done < "$MACHO_LIST"
  [ -s "$NEW_MACHO" ] || break
  /bin/cat "$NEW_MACHO" >> "$MACHO_LIST"
  /usr/bin/sort -u "$MACHO_LIST" -o "$MACHO_LIST"
done

printf 'Relocating %s Mach-O files\n' "$(wc -l < "$MACHO_LIST" | tr -d ' ')"
while IFS= read -r item; do
  /bin/chmod u+w "$item"
  /usr/bin/codesign --remove-signature "$item" 2>/dev/null || true
  /usr/bin/otool -L "$item" | /usr/bin/tail -n +2 | /usr/bin/awk '{print $1}' | while IFS= read -r dependency; do
    case "$dependency" in
      /opt/homebrew/*|/usr/local/*)
        replacement="@rpath/$(basename "$(/bin/realpath "$dependency")")"
        /usr/bin/install_name_tool -change "$dependency" "$replacement" "$item"
        ;;
    esac
  done
  case "$item" in
    *.dylib)
      /usr/bin/install_name_tool -id "@rpath/$(basename "$item")" "$item"
      ;;
  esac
  case "$item" in
    "$WORK/apache/bin/"*|"$WORK/php/bin/"*|"$WORK/php/sbin/"*|"$WORK/mariadb/bin/"*)
      if ! /usr/bin/otool -l "$item" | /usr/bin/grep -A2 LC_RPATH | /usr/bin/grep -Fq '@executable_path/../../lib'; then
        /usr/bin/install_name_tool -add_rpath '@executable_path/../../lib' "$item"
      fi
      ;;
  esac
done < "$MACHO_LIST"

# Apple Silicon refuses to launch Mach-O files whose original signatures were
# invalidated by install_name_tool. Ad-hoc signatures make the staged payload
# executable for local testing; release packaging replaces them with the
# configured Developer ID identity.
while IFS= read -r item; do
  /usr/bin/codesign --force --sign - "$item"
done < "$MACHO_LIST"

bash "$PROJECT_DIR/scripts/verify-portable-runtime.sh" "$WORK"
/usr/bin/xattr -cr "$WORK" 2>/dev/null || true

# Replace only the generated staging directory after the new payload validates.
if [ -e "$FINAL_STAGE" ]; then
  backup_stage="$BUILD_ROOT/previous-stage-$(date +%Y%m%d%H%M%S)"
  /bin/mv "$FINAL_STAGE" "$backup_stage"
  printf 'Previous generated stage moved to %s\n' "$backup_stage"
fi
/bin/mv "$WORK" "$FINAL_STAGE"
trap - EXIT
printf 'Portable runtime ready: %s\n' "$FINAL_STAGE"
/usr/bin/du -sh "$FINAL_STAGE"
