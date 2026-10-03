# 0.11.0 本地验收记录

日期：2026-10-04。版本：0.11.0（build 16）。本地测试包使用 ad-hoc 签名，未做 Developer ID 签名或 Apple 公证。

## 已实跑通过

- `MACSTACK_RUNTIME_ROOT="$PWD/runtime/stage" swift test --disable-sandbox --scratch-path "$BUILD_CACHE"`：120 项通过。
- 使用暂存便携运行时，依次运行 `macstackctl` 的 `prepare`、`smoke-test`、`sites-smoke-test`、`htaccess-smoke-test`、`prepare-database`、`database-smoke-test`、`database-backup-smoke-test`、`prepare-phpmyadmin`、`full-smoke-test`、`audit-xampp`，十项全部通过。
- 检查包括重复启动、停服后立即重启、多站点 PHP/静态文件、404 分类、端口冲突回滚、伪静态、敏感文件拦截、Laravel/Symfony 风格 `.htaccess`。
- 数据库检查包括中文、视图、触发器的普通/流式恢复，坏 SQL 报错、写入中取消恢复、以 `--` 开头库名的导出，以及导出文件 0600 权限。
- `bash scripts/package-release.sh`：成功生成 DMG、ZIP 与 SHA-256；便携运行时检查 290 个 Mach-O，无 Homebrew 动态库引用；161 个许可证文件、63 个组件目录均通过结构检查。
- ZIP 解压后的应用通过 `codesign --verify --deep --strict`；DMG 通过 `hdiutil verify`；两份 SHA-256 均通过。
- 从交付 ZIP 安装 0.11.0 到用户应用目录，启动后观察到应用进程与内置 MariaDB 进程正常运行。

## 验收边界

- 实跑前已备份用户网站、数据库、设置及旧应用；没有重新初始化用户数据库。验收创建的临时数据库由命令自行清理。
- 便携组件版本仍为 Apache 2.4.68、PHP 8.2.33、MariaDB 11.4.13、phpMyAdmin 5.2.3；本次不升级数据库内核。
- 应用内 ATS/SwiftUI 点击验收尚未完成：界面控制连接两次返回 `Sky Computer Use native pipe closed before response`。CLI 网站探测通过不能替代应用内 ATS 验证。
- 尚未在没有 Homebrew 的独立 Mac 上运行。包的结构与动态库检查不能替代此项。
- 本地未发现 Developer ID Application 证书。项目许可证未选定，第三方源码提供说明仍为草稿，因此本次安装包仅作本地验收，不公开发行。

## GitHub

源码、版本说明和验收记录已同步到 `main`。提交 `0529caa` 的 [CI 运行](https://github.com/Tsagi01/MacStack/actions/runs/37139865723) 已成功，包含构建与单元测试。工作流使用原生 ARM64 `macos-15` 与完整 Xcode 16.4；应用最低运行系统仍为 macOS 14。运行环境依据 [GitHub runner 文档](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) 与 [macOS 15 ARM64 镜像清单](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md) 选择。
