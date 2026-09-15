#!/bin/bash
# 刷新 vendor/spdx 下的许可证正文。
#
# **只在需要时手动运行**；发行构建（build-portable-runtime.sh）只读取 vendor 目录，
# 完全不联网。
#
# SPDX 数据版本固定在下面的 SPDX_TAG。不要改成 main —— main 是移动目标，
# 会让发行包的内容不可复现，也引入供应链风险。
set -euo pipefail

SPDX_TAG="v3.28.0"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$PROJECT_DIR/vendor/spdx"
MANIFEST="$VENDOR/MANIFEST.sha256"
BASE_URL="https://raw.githubusercontent.com/spdx/license-list-data/$SPDX_TAG/json/details"

# 需要 vendored 正文的许可证。
#
# 只有「组件自己的安装目录里确实找不到任何许可证文件」时才需要列在这里。
# 判定方法见 collect-runtime-licenses.sh 的输出：它会列出未收集到文件的组件。
IDS=(
  "MPL-2.0"    # ca-certificates
  "blessing"   # sqlite（公有领域声明）
  "Zlib"       # tidy-html5
)

mkdir -p "$VENDOR"
printf 'SPDX 数据版本：%s\n\n' "$SPDX_TAG" > "$VENDOR/README.md"
cat >> "$VENDOR/README.md" <<'EOF'
本目录的许可证正文取自 SPDX license list（https://github.com/spdx/license-list-data），
版本固定在 refresh-license-texts.sh 顶部的 SPDX_TAG。

由 `scripts/refresh-license-texts.sh` 生成，请勿手工编辑。
校验和见 MANIFEST.sha256。
EOF

: > "$MANIFEST"
for id in "${IDS[@]}"; do
  printf '获取 %s ... ' "$id"
  json="$(/usr/bin/curl -fsSL "$BASE_URL/$id.json")" || { printf '失败\n' >&2; exit 1; }
  # 从 SPDX JSON 里取出 licenseText，写到 <ID>.txt。
  printf '%s' "$json" | /usr/bin/python3 -c '
import json, sys, pathlib
data = json.load(sys.stdin)
text = data["licenseText"]
if not text.endswith("\n"):
    text += "\n"
pathlib.Path(sys.argv[1]).write_text(text, encoding="utf-8")
' "$VENDOR/$id.txt"
  digest="$(/usr/bin/shasum -a 256 "$VENDOR/$id.txt" | /usr/bin/awk '{print $1}')"
  printf '%s  %s.txt\n' "$digest" "$id" >> "$MANIFEST"
  printf '%s 字节\n' "$(wc -c < "$VENDOR/$id.txt" | tr -d ' ')"
done

printf '\nSPDX 数据版本 %s，共 %s 个许可证正文。\n' "$SPDX_TAG" "${#IDS[@]}"
printf '校验和已写入 %s\n' "$MANIFEST"
