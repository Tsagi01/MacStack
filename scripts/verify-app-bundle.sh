#!/bin/bash
# 只读检查一个打包好的 MacStack.app 是否真的自包含。
#
# 这是「在没有 Homebrew 的机器上能不能跑」的可验证部分：真正启动一次需要一台干净机器，
# 但**依赖是否泄漏**可以在这里查出来——而泄漏正是最常见的不自包含原因。
#
# 用法：scripts/verify-app-bundle.sh [path/to/MacStack.app]
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:-$PROJECT_DIR/dist/MacStack.app}"

[ -d "$APP_DIR" ] || { printf '找不到应用包：%s\n' "$APP_DIR" >&2; exit 1; }

# 解析成物理路径。`dist/MacStack.app` 是指向构建缓存的**符号链接**，
# 不解析的话 `find` 不会跟进链接、也进不去，符号链接检查会静默通过（假阴性）。
APP_DIR="$(cd "$APP_DIR" && pwd -P)"
RUNTIME_DIR="$APP_DIR/Contents/Resources/runtime"
BINARY="$APP_DIR/Contents/MacOS/MacStack"
PLIST="$APP_DIR/Contents/Info.plist"

failures=0
fail() { printf '  ✘ %s\n' "$1" >&2; failures=$((failures + 1)); }
ok() { printf '  ✔ %s\n' "$1"; }

printf '检查应用包：%s\n' "$APP_DIR"

# ── 1. 结构 ──────────────────────────────────────────────────
printf '\n结构\n'
for item in "$BINARY" "$PLIST" "$RUNTIME_DIR/manifest.json"; do
  [ -e "$item" ] && ok "${item#"$APP_DIR"/}" || fail "缺少 ${item#"$APP_DIR"/}"
done

# ── 2. Info.plist ────────────────────────────────────────────
printf '\nInfo.plist\n'
for key in CFBundleExecutable CFBundleIdentifier CFBundleShortVersionString CFBundleVersion; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" 2>/dev/null || true)"
  [ -n "$value" ] && ok "$key = $value" || fail "缺少 $key"
done
# 探测用真实 .localhost 域名，因此必须声明对应的传输安全例外；
# 两处脱节时应用里会请求失败而单元测试照样通过。
if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity:NSExceptionDomains:localhost" "$PLIST" >/dev/null 2>&1; then
  ok "已声明 localhost 的传输安全例外"
else
  fail "缺少 NSAppTransportSecurity:NSExceptionDomains:localhost（网站探测会失败）"
fi

# ── 3. 应用二进制 ────────────────────────────────────────────
printf '\n应用二进制\n'
if [ -f "$BINARY" ]; then
  if /usr/bin/file -b "$BINARY" | /usr/bin/grep -q 'arm64'; then
    ok "arm64"
  else
    fail "不是 arm64：$(/usr/bin/file -b "$BINARY")"
  fi
  if /usr/bin/otool -L "$BINARY" | /usr/bin/grep -Eq '/opt/homebrew|/usr/local'; then
    fail "链接了 Homebrew 或 /usr/local 下的库："
    /usr/bin/otool -L "$BINARY" | /usr/bin/grep -E '/opt/homebrew|/usr/local' >&2
  else
    ok "只链接系统框架"
  fi
fi

# ── 4. 包内符号链接不得指向包外 ──────────────────────────────
#
# 指向包外的链接在别的机器上必然断掉。构建脚本已经清理过一轮，
# 这里再确认一次，因为新增组件时很容易重新引入。
printf '\n符号链接\n'
escaped=0
while IFS= read -r link; do
  target="$(/usr/bin/readlink "$link")"
  case "$target" in
    /*) resolved="$target" ;;
    *)  resolved="$(cd "$(dirname "$link")" && pwd)/$target" ;;
  esac
  case "$resolved" in
    "$APP_DIR"/*) ;;
    *) printf '    %s → %s\n' "${link#"$APP_DIR"/}" "$target" >&2; escaped=$((escaped + 1)) ;;
  esac
done < <(/usr/bin/find "$APP_DIR" -type l -print)
[ "$escaped" -eq 0 ] && ok "没有指向包外的链接" || fail "$escaped 个符号链接指向包外"

# ── 5. 便携运行时 ────────────────────────────────────────────
#
# 复用运行时校验脚本，避免两处各写一份判断。它会检查每个 Mach-O 的架构与
# 动态库引用，以及许可证覆盖。
printf '\n便携运行时\n'
if [ -f "$RUNTIME_DIR/manifest.json" ]; then
  if bash "$PROJECT_DIR/scripts/verify-portable-runtime.sh" "$RUNTIME_DIR"; then
    ok "运行时校验通过"
  else
    fail "运行时校验未通过（详见上方输出）"
  fi
fi

# ── 结论 ─────────────────────────────────────────────────────
printf '\n'
if [ "$failures" -eq 0 ]; then
  printf '应用包检查通过。\n'
  printf '注意：这只证明「依赖没有泄漏」，不等于「在干净机器上能启动」。\n'
  printf '首次公开发行前仍需在一台没有 Homebrew 的机器上实际跑一遍。\n'
else
  printf '应用包检查发现 %s 处问题。\n' "$failures" >&2
  exit 1
fi
