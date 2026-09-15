#!/bin/bash
# 收集便携运行时的第三方许可证与声明文件。
#
# 用法: collect-runtime-licenses.sh <stage-dir> [brew]
#
# 之前的实现让 licenses/ 下的 59 个目录全部为空，根因有三个，都要处理：
#
#   1. `brew --prefix` 返回的是 `opt` 符号链接，而 find **不会下降到作为起点的
#      符号链接**，因此循环体在起点就停住了 —— 必须先 realpath 解析真实路径；
#   2. 匹配模式漏了 COPYRIGHT（libpq 就只有 COPYRIGHT，没有 LICENSE）；
#   3. 深度限制 2 层会漏掉 phpmyadmin 这类把 LICENSE 放在 share/<name>/ 下的组件。
#
# 另外会扫描暂存后的组件目录：暂存会改变布局（phpmyadmin 的 LICENSE 在暂存后
# 位于组件根目录），而暂存产物才是真正随包分发的东西。
set -euo pipefail

STAGE="${1:?用法: collect-runtime-licenses.sh <stage-dir> [brew]}"
BREW="${2:-/opt/homebrew/bin/brew}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$PROJECT_DIR/vendor/spdx"
LICENSES="$STAGE/licenses"

MAIN_FORMULAS=(httpd php@8.2 mariadb@11.4 phpmyadmin)
# 许可证文件的常见命名，大小写不敏感。
NAME_PATTERNS=(-iname 'license*' -o -iname 'copying*' -o -iname 'notice*' -o -iname 'copyright*')
# 依赖闭包里有些组件的许可证文件层级较深（phpmyadmin 在 share/<name>/ 下）。
MAX_DEPTH=4

[ -x "$BREW" ] || { printf 'portable-runtime: 找不到 brew：%s\n' "$BREW" >&2; exit 1; }
[ -d "$STAGE" ] || { printf 'portable-runtime: 暂存目录不存在：%s\n' "$STAGE" >&2; exit 1; }

# 每次重建，避免上一次的残留被误当成「已收集」。
rm -rf "$LICENSES"
mkdir -p "$LICENSES"

# 依赖闭包。顺序固定，保证输出可复现。
FORMULAS=("${MAIN_FORMULAS[@]}")
while IFS= read -r dependency; do
  [ -n "$dependency" ] || continue
  already=0
  for existing in "${FORMULAS[@]}"; do
    [ "$existing" = "$dependency" ] && already=1 && break
  done
  [ "$already" -eq 0 ] && FORMULAS+=("$dependency")
done < <("$BREW" deps --union "${MAIN_FORMULAS[@]}")

printf '收集 %s 个组件的许可证文件\n' "${#FORMULAS[@]}"

copy_license_files() {
  # $1 源根目录；$2 目标组件目录；$3 深度上限
  local source_root="$1" destination="$2" depth="$3"
  local item relative target
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    relative="${item#"$source_root"/}"
    target="$destination/$relative"
    mkdir -p "$(dirname "$target")"
    # -L 解引用：Homebrew 有时把 LICENSE 做成符号链接。
    /bin/cp -Lf "$item" "$target"
  done < <(find "$source_root" -maxdepth "$depth" \
             \( -type f -o -type l \) \( "${NAME_PATTERNS[@]}" \) -print 2>/dev/null | LC_ALL=C sort)
}

for formula in "${FORMULAS[@]}"; do
  prefix="$("$BREW" --prefix "$formula" 2>/dev/null || true)"
  if [ -z "$prefix" ] || [ ! -d "$prefix" ]; then
    printf '  跳过 %s：无法确定安装路径\n' "$formula"
    continue
  fi
  # 关键修正：解析 opt 符号链接，否则 find 不会下降到真实目录。
  real_prefix="$(/bin/realpath "$prefix")"
  directory="$LICENSES/${formula//\//_}"
  mkdir -p "$directory"
  copy_license_files "$real_prefix" "$directory" "$MAX_DEPTH"
done

# 暂存产物才是真正随包分发的内容，单独扫一遍。
for component in apache php mariadb phpmyadmin; do
  [ -d "$STAGE/$component" ] || continue
  directory="$LICENSES/staged-$component"
  mkdir -p "$directory"
  copy_license_files "$STAGE/$component" "$directory" 3
done

# Homebrew 生成的 SPDX SBOM 是有价值的合规产物，归集而不是丢弃。
mkdir -p "$LICENSES/sbom"
for formula in "${FORMULAS[@]}"; do
  prefix="$("$BREW" --prefix "$formula" 2>/dev/null || true)"
  [ -n "$prefix" ] || continue
  sbom="$(/bin/realpath "$prefix")/sbom.spdx.json"
  [ -f "$sbom" ] && /bin/cp -Lf "$sbom" "$LICENSES/sbom/${formula//\//_}.spdx.json"
done

/usr/bin/python3 "$PROJECT_DIR/scripts/license_manifest.py" \
  "$BREW" "$LICENSES" "$VENDOR" "${FORMULAS[@]}"

printf '许可证文件总数：%s\n' "$(find "$LICENSES" -type f | wc -l | tr -d ' ')"
