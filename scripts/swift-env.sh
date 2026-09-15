#!/bin/bash
# 仅在当前脚本进程选择工具链，不运行 xcode-select --switch。
# 当前机器的 CLT 缺少 Swift Testing；优先使用完整 Xcode。
if [ -z "${DEVELOPER_DIR:-}" ]; then
    SELECTED_DEVELOPER="$(xcode-select -p)"
    if [[ "$SELECTED_DEVELOPER" == *CommandLineTools* ]]; then
        if [ -d /Applications/Xcode.app/Contents/Developer ]; then
            export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
        elif [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
            export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
        fi
    fi
fi
# 将编译缓存放在非同步目录，避免 Documents 文件提供器给测试包
# 附加 FinderInfo，导致 Xcode 的签名步骤失败。
BUILD_CACHE="${MACSTACK_BUILD_CACHE:-$HOME/Library/Caches/MacStack/SwiftBuild}"
# 必须 export：调用方经常再用 `bash -c` / `env` 启动子进程，不导出的话
# 子进程读到的是空值，SwiftPM 会退回 `$PWD/out`，把产物建在 Documents 下
# —— 正是上面这段注释要避免的情况。产物落在 Documents 里时，测试包的
# codesign 步骤会因为 FinderInfo 扩展属性而失败。
export BUILD_CACHE
