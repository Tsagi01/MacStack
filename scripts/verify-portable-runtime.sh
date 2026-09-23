#!/bin/bash
# Read-only structural/linkage verification for a staged portable runtime.
set -euo pipefail

ROOT="${1:-}"
[ -n "$ROOT" ] || { printf 'usage: %s RUNTIME_ROOT\n' "$0" >&2; exit 64; }
[ -f "$ROOT/manifest.json" ] || { printf 'missing manifest.json\n' >&2; exit 1; }

required=(
  "$ROOT/apache/bin/httpd"
  "$ROOT/php/bin/php"
  "$ROOT/php/sbin/php-fpm"
  "$ROOT/mariadb/bin/mariadbd"
  "$ROOT/mariadb/bin/mariadb-install-db"
  "$ROOT/mariadb/bin/mariadb-admin"
  "$ROOT/mariadb/bin/mariadb"
  "$ROOT/mariadb/bin/mariadb-dump"
  "$ROOT/phpmyadmin/index.php"
)
for item in "${required[@]}"; do
  [ -e "$item" ] || { printf 'missing required runtime file: %s\n' "$item" >&2; exit 1; }
done

# manifest.json 里声明的 phpAPI 必须与实际暂存的 PHP 一致。
#
# 它被用来拼 `extension_dir`（见 WebStack.swift 里的 phpExtensionDirectory(api:)），
# 对不上时 PHP 加载不了**任何**扩展 —— phpMyAdmin 和所有用数据库的站点都会坏，
# 而**没有任何东西会报错**。清单是手工维护的（runtime/manifest.template.json），
# 改了 build-portable-runtime.sh 里的公式版本却忘了同步它，就会静默漂移。
#
# 校验方式是「声明的 API 在 php/lib/php/ 下确实存在」——暂存的 PHP 会在这个目录里
# 放自己的扩展，目录名就是 API 号，不需要运行它就能判断。
manifest_php_api="$(/usr/bin/plutil -extract phpAPI raw -o - "$ROOT/manifest.json" 2>/dev/null || true)"
if [ -n "$manifest_php_api" ] && [ ! -d "$ROOT/php/lib/php/$manifest_php_api" ]; then
  printf 'manifest.json 的 phpAPI=%s 与实际暂存的 PHP 不符。\n' "$manifest_php_api" >&2
  printf 'php/lib/php/ 下实际存在：\n' >&2
  /bin/ls "$ROOT/php/lib/php/" >&2 || true
  printf '请同步 runtime/manifest.template.json。\n' >&2
  exit 1
fi

MACHO_LIST="$(mktemp -t macstack-runtime-macho)"
trap 'rm -f "$MACHO_LIST"' EXIT
find "$ROOT/apache" "$ROOT/php" "$ROOT/mariadb" "$ROOT/lib" -type f -print | while IFS= read -r item; do
  if /usr/bin/file -b "$item" | /usr/bin/grep -q 'Mach-O'; then printf '%s\n' "$item" >> "$MACHO_LIST"; fi
done

failures=0
while IFS= read -r item; do
  if ! /usr/bin/file -b "$item" | /usr/bin/grep -q 'arm64'; then
    printf 'non-arm64 Mach-O: %s\n' "$item" >&2
    failures=1
  fi
  if /usr/bin/otool -L "$item" | /usr/bin/grep -Eq '/opt/homebrew|/usr/local'; then
    printf 'non-portable dylib reference: %s\n' "$item" >&2
    /usr/bin/otool -L "$item" >&2
    failures=1
  fi
done < "$MACHO_LIST"
[ "$failures" -eq 0 ] || exit 1

# 许可证覆盖检查。
#
# 之前 licenses/ 下的组件目录全部为空，而 README 却声称「已附带许可证文件」。
# 只判断「总文件数大于 0」的验收太弱：只要有一个组件有文件就会通过，其余空目录照样漏过。
# 因此这里**逐组件**检查，并且要求清单文件存在。
LICENSES="$ROOT/licenses"
[ -d "$LICENSES" ] || { printf 'missing licenses directory: %s\n' "$LICENSES" >&2; exit 1; }
[ -f "$LICENSES/THIRD-PARTY.md" ] || { printf 'missing licenses/THIRD-PARTY.md\n' >&2; exit 1; }

empty_components=()
for directory in "$LICENSES"/*/; do
  [ -d "$directory" ] || continue
  case "$(basename "$directory")" in
    sbom) continue ;;
  esac
  if [ -z "$(find "$directory" -type f -print -quit)" ]; then
    empty_components+=("$(basename "$directory")")
  fi
done
if [ "${#empty_components[@]}" -gt 0 ]; then
  printf 'licenses/ 下这些组件没有任何许可证文件：\n' >&2
  printf '  - %s\n' "${empty_components[@]}" >&2
  printf '组件没有自带许可证文件时，应由 collect-runtime-licenses.sh 从 vendor/spdx 补齐。\n' >&2
  exit 1
fi

license_file_count="$(find "$LICENSES" -type f | wc -l | tr -d ' ')"
printf 'Verified portable runtime: %s Mach-O files, no Homebrew dylib references.\n' "$(wc -l < "$MACHO_LIST" | tr -d ' ')"
printf 'Verified licenses: %s files across %s component directories.\n' \
  "$license_file_count" "$(find "$LICENSES" -mindepth 1 -maxdepth 1 -type d ! -name sbom | wc -l | tr -d ' ')"
