# MacStack

面向 Apple Silicon 的原生 macOS 本地 Web 工作台。当前为 **0.10.0 开发预览**：Apache、PHP-FPM、MariaDB、phpMyAdmin 及动态库已经可以随应用打包，最终用户运行核心 Web 环境不再需要 Homebrew。多站点、`.localhost` 域名、开发 HTTPS、Perl/CGI、PHP 扩展管理、项目向导、备份恢复和旧 XAMPP 逻辑迁移也已接入。正式自动更新、Developer ID 公证和可选 FTP 服务仍未完成，因此还不应称为所有场景下的完整 XAMPP 替代品。

[![GitHub Release](https://img.shields.io/github/v/release/Tsagi01/MacStack?include_prereleases&label=release)](https://github.com/Tsagi01/MacStack/releases)
![Platform](https://img.shields.io/badge/macOS-14%2B-black)
![Architecture](https://img.shields.io/badge/Apple%20Silicon-ARM64-00bcd4)

## 下载与安装

MacStack 面向 **Apple Silicon（M1/M2/M3/M4 及后续芯片）和 macOS 14+**，不支持 Intel Mac。

1. 前往 [GitHub Releases](https://github.com/Tsagi01/MacStack/releases/latest) 下载 `MacStack-0.10.0-arm64.dmg`（推荐）或 ZIP。
2. 打开 DMG，把 `MacStack.app` 拖到“应用程序”文件夹；ZIP 用户解压后移动应用即可。
3. 第一次启动时，macOS 可能因为当前开发预览包尚未 Apple 公证而阻止打开。请在 Finder 中按住 Control 点击 MacStack，选择“打开”，再次确认。
4. 点击 **Start All**，然后打开 `http://localhost:8080`。默认网站目录是 `~/Library/Application Support/MacStack/runtime/www`，也可以在“网站”页面点击 **Open Application Folder**。

DMG 和 ZIP 已包含 Apache、PHP-FPM、MariaDB、phpMyAdmin 及所需 ARM64 动态库。**使用安装包的普通用户不需要 Homebrew，也不需要 Rosetta。** 下载页同时提供 SHA-256 文件用于完整性核验。

## 适合做什么

- 学习 PHP、HTML、CSS、JavaScript 和“动态内容生成”课程。
- 创建多个互不覆盖的 PHP 项目，并为项目单独建立数据库和访问端口。
- 在浏览器运行 PHP 页面、使用 MariaDB 保存数据，并通过 phpMyAdmin 管理数据库。
- 从旧 XAMPP 只读检查并迁移网站或数据库，不会删除原环境。

它不是云服务器，也不会把网站自动发布到互联网。MacStack 当前不托管 FTP 服务；本机开发通常可直接用 Finder 或 VS Code 编辑项目文件。

## 五分钟开始第一个网站

1. 打开 MacStack，在“总览”点击 **Start All**。
2. 进入“网站”，点击 **创建 PHP 项目**。
3. 输入项目名；如需数据库，保留“同时创建数据库”。
4. 创建后打开项目文件夹，在 `public/index.php` 中编写页面。
5. 返回 MacStack，点击该网站的“打开”按钮在浏览器查看结果。

图片、CSS 和 JavaScript 都放在项目目录内，例如 `public/images/photo.jpg`、`public/css/style.css`、`public/js/app.js`。PHP/HTML 中分别使用 `/images/photo.jpg`、`/css/style.css` 和 `/js/app.js` 引用。

## 已实现

- SwiftUI 原生双栏界面：总览、网站、数据库、PHP 扩展、迁移、日志、环境、设置。
- Start All / Stop All、上次运行状态恢复，以及可选的 Web/数据库随应用启动。
- 强制退出后的残留 PID 会先核对命令行与 MacStack 专属配置路径，再清理确认属于 MacStack 的进程；不按名称批量杀进程。
- PHP 项目向导可生成 `public/index.php`、样式、README、`.gitignore` 和不含真实密码的 PDO 模板，并可同时创建 MariaDB 数据库、登记网站与分配端口。
- 优先识别应用内版本化 ARM64 便携运行时；源码开发版缺少内置包时才回退查找 `/opt/homebrew/opt`。
- 读取 Mach-O 头部，识别主程序是否包含 ARM64；不执行候选文件。
- 网站目录登记、公开目录选择、稳定独立端口、启用/停用、浏览器访问、Finder 与错误日志入口；登记不复制网站，移出不删除文件。
- “Open Application Folder” 按钮可直接打开 `localhost:8080` 对应的默认网站目录。
- 每个已启用网站生成独立的本机 Apache 监听与日志，支持 PHP-FPM、静态 HTML/CSS，并默认拒绝目录列表、符号链接跟随及 `.env`、`.git` 等隐藏路径。
- HTTP/数据库/网站端口校验、真实占用检测、原子保存和配置版本迁移；旧 schema 首次保存前保留备份。
- 可选择已安装的 PHP 8.2–8.5；指定版本缺失时明确报错，不静默换成其他版本。
- 可选 `.localhost` 本地域名、开发 HTTPS 自签名证书与当前用户登录钥匙串信任入口；默认关闭。
- 可选 Perl/CGI，已用真实 ARM64 Apache + `/usr/bin/perl` 完成 HTTP 运行测试；默认关闭。
- 配置损坏时提示并禁用写入，避免覆盖用户原文件。
- 解析应用内或开发机 Homebrew ARM64 Apache/PHP-FPM 的真实路径与版本。
- 生成独立的 Apache、PHP-FPM、PHP 配置、日志、PID、socket 和测试网站目录。
- 候选配置先做 Apache/PHP-FPM 语法检查，通过后才替换生效配置；运行中的网站变更采用受控重启，失败时恢复上一份配置与运行状态。
- 独立的内部 PHP HTTP 与逐站 HTTP 健康检查、重复启动保护和正常停止；用户可自由修改默认 `index.php`，不会因此被误判为启动失败。
- 应用退出前停止它自己启动的 Web 服务；停止失败时取消退出，不强杀进程。
- MariaDB 独立数据目录、3307 本机监听、真实查询健康检查和正常关闭。
- 数据库页面可刷新业务库列表、把单个数据库完整导出为 SQL，并在二次确认后恢复 SQL；导出覆盖表、数据、视图、触发器、事件和存储过程。
- 大 SQL 恢复带可用空间预检、实际读入进度和取消入口；取消后明确提示可能已经执行了前段 SQL。
- 手动备份登记历史；可按 1–168 小时间隔在 MacStack 打开且数据库运行时自动备份全部业务库。
- 可创建业务数据库并复制不含钥匙串密码的 PDO 连接模板。
- 导出先写临时文件，成功后才发布最终备份；不覆盖同名文件，SQL 文件权限设为仅当前用户可读写。
- 应用每两秒检查自己管理的 Apache、PHP-FPM 和 MariaDB；进程意外退出时更新界面状态并清理 Web 半运行状态。
- 数据目录所有权标记；非空未知目录及符号链接会被拒绝，不会自动重建数据库。
- `macstack@127.0.0.1` 开发凭据保存在 macOS 钥匙串，不写入配置或日志。
- phpMyAdmin 5.2.3 独立副本、cookie 登录、随机 cookie 密钥和仅本机 Apache 路由。
- UI 可准备、启动和停止 Web/数据库，并打开 phpMyAdmin、按需复制密码；剪贴板中的密码 60 秒后清除。
- 开发命令 `macstackctl` 支持准备配置和端到端冒烟测试。
- 旧 XAMPP 只读审计：列出网站候选、数据库目录分类、旧二进制架构和非敏感配置摘要，并生成本地 Markdown 报告。
- 网站副本迁移：用户选择目标目录后显示文件数/大小预览并二次确认；拒绝符号链接和既有目标，复制前后逐文件验证 SHA-256，失败时清理未发布的临时副本。
- 旧数据库逻辑迁移：使用临时权限 0600 的连接文件只读连接正在运行的旧 XAMPP 数据库，逐库确认后逻辑导出并导入 MacStack；密码不保存，源数据库不修改。
- 独立 PHP 扩展页区分编译内置、已启用、已安装未启用、未安装和非 ARM64 模块；动态扩展使用 MacStack 私有 `php.d`，不会修改 Homebrew 全局 `php.ini`。
- 可校验后启用/停用任意已安装的 ARM64 `.so`；可确认后通过白名单 PECL 安装 Xdebug、Imagick、Redis，Imagick 会按需安装 Homebrew 的 ImageMagick 依赖。
- 扩展变更先在临时扫描目录验证，成功后原子替换并备份；Web 运行时受控重启，失败会恢复上一份配置。
- Composer、Perl 和 ProFTPD 检测；Composer 项目可在确认后执行 `composer install`。
- 发行包显示内置运行时版本，不出现 Homebrew 安装入口；仅未嵌入运行时的源码开发包保留 Homebrew 依赖清单与显式安装入口。
- `scripts/build-portable-runtime.sh` 可在构建机整理固定版本的 Apache、PHP、MariaDB、phpMyAdmin，递归收集依赖库、改写为 `@rpath`、移除外部断链、收集许可证与声明文件并完成 ARM64/链接校验。许可证收集在 `scripts/collect-runtime-licenses.sh`：按组件收录自带的 LICENSE/COPYING/NOTICE/COPYRIGHT，组件确实没有时从 `vendor/spdx` 取固定版本的 SPDX 正文补齐，取不到则构建失败并列出清单。`licenses/THIRD-PARTY.md` 记录每个组件的版本与 SPDX 标识符，`licenses/sbom/` 收录 Homebrew 生成的 SPDX SBOM。
- 超过 5 MB 的服务日志自动轮转并保留 3 份，也可停服后手动整理。
- 本地 ARM64 `.app`、DMG/ZIP/SHA-256 打包脚本与核心行为测试；发布脚本支持外部提供的 Developer ID 和公证钥匙串配置。

## 当前不做的事

应用不会隐式安装、升级或启动 Homebrew 服务；只有用户在依赖页面明确确认时才执行白名单内的 `brew install`。旧 XAMPP 网站和数据库迁移也都要求逐项确认，绝不删除旧环境。
管理应用和本次真实 Web、HTTPS 与 Perl/CGI 链路均在 ARM64 Apache/PHP 上运行；扩展管理会拒绝 Intel-only 动态库，但每个第三方 PHP 扩展和真实业务项目仍需逐个兼容性验证。
服务仍随 MacStack 应用会话运行；“自动启动”指打开 MacStack 时恢复，不是常驻 LaunchAgent。
ProFTPD 当前仅检测、不托管 FTP 服务；对本机网站目录直接编辑通常不需要 FTP。便携运行时已经完成首版，但构建机目前仍用 Homebrew 作为固定版本组件来源；最终 `.app` 的核心服务不依赖 Homebrew。更新服务器、Developer ID 证书和 Apple 公证凭据不包含在源码中。

便携运行时会随包提供组件自带的许可证与声明文件、`licenses/THIRD-PARTY.md` 清单以及 Homebrew 生成的 SPDX SBOM，但**这不构成合规结论**。至少 MariaDB 的 `GPL-2.0-only`、PHP 许可证表达式中的 `LGPL-2.1-only` / `LGPL-2.1-or-later`、以及表达式里的 `LicenseRef-*`（Homebrew 内部标识符，不在 SPDX 列表中）需要单独做正式审核，详见 `licenses/THIRD-PARTY.md` 末尾的待审清单。

## 开发与运行

要求：Apple Silicon、macOS 14+、支持 Swift 6 的完整 Xcode（测试需要 Swift Testing 模块）。
部署目标是 macOS 14；目前只在开发机器验证，不代表已完成各版本系统测试。

获取源码：

```sh
git clone https://github.com/Tsagi01/MacStack.git
cd MacStack
```

在此目录运行：

```sh
bash scripts/test.sh
bash scripts/build-portable-runtime.sh
bash scripts/build-app.sh
open dist/MacStack.app
```

开发验收命令：

```sh
source scripts/swift-env.sh
swift run --scratch-path "$BUILD_CACHE" macstackctl prepare
swift run --scratch-path "$BUILD_CACHE" macstackctl smoke-test
swift run --scratch-path "$BUILD_CACHE" macstackctl prepare-database
swift run --scratch-path "$BUILD_CACHE" macstackctl database-smoke-test
swift run --scratch-path "$BUILD_CACHE" macstackctl database-backup-smoke-test
swift run --scratch-path "$BUILD_CACHE" macstackctl prepare-phpmyadmin
swift run --scratch-path "$BUILD_CACHE" macstackctl full-smoke-test
swift run --scratch-path "$BUILD_CACHE" macstackctl sites-smoke-test
swift run --scratch-path "$BUILD_CACHE" macstackctl htaccess-smoke-test
swift run --scratch-path "$BUILD_CACHE" macstackctl audit-xampp /Applications/XAMPP
```

`htaccess-smoke-test` 会真实启动 Apache，验证伪静态、敏感文件拦截、`.htaccess` 开关和预检分类。它需要绑定本机端口，因此在受限环境（沙箱、CI 容器）里跑不通——那种环境下 `swift test` 也要加 `--disable-sandbox`，否则 SwiftPM 编译 manifest 时会报 `sandbox_apply: Operation not permitted`。

也可用 Xcode 打开 `Package.swift`，选择 MacStack 可执行产品运行。
脚本在默认工具链为 Command Line Tools 时，会为当前进程选择已安装的 Xcode / Xcode beta；不会更改系统的 xcode-select 设置。也可显式设置 `DEVELOPER_DIR` 选择其他 Xcode。
编译缓存默认位于 `~/Library/Caches/MacStack/SwiftBuild`，避免 Documents 同步元数据干扰构建签名。可用 `MACSTACK_BUILD_CACHE` 覆盖。`dist/` 仅包含可重新生成的应用包。
`scripts/build-portable-runtime.sh` 仅供发布构建机运行，生成物位于被忽略的 `runtime/stage/`；普通用户不运行它。`scripts/package-release.sh` 可把该运行时嵌入 DMG/ZIP 并生成 SHA-256。没有开发者账号环境变量时仍是 ad-hoc 签名测试包；完整签名与公证步骤见 `docs/DISTRIBUTION.md`。

## 数据位置

设置文件位于：

```text
~/Library/Application Support/MacStack/workspace.json
```

生成 Web 配置后使用：

```text
~/Library/Application Support/MacStack/runtime/config
~/Library/Application Support/MacStack/runtime/logs
~/Library/Application Support/MacStack/runtime/run
~/Library/Application Support/MacStack/runtime/www
~/Library/Application Support/MacStack/runtime/mariadb-data
~/Library/Application Support/MacStack/runtime/phpmyadmin
~/Library/Application Support/MacStack/runtime/tls
~/Library/Application Support/MacStack/backups
~/Library/Application Support/MacStack/migration-reports
```

设置文件仅保存 schemaVersion、端口、网站绝对路径、公开目录及启用状态，不含数据库密码。schema 1 会在内存中迁移为 schema 2，首次写回前保留 `workspace-v1-backup.json`。默认测试页只在不存在时创建，不覆盖已有 `index.php`。

## 文件职责

```text
Package.swift                       构建目标与依赖（无第三方 Swift 包）
Sources/MacStackCore/
  Models.swift                      组件、服务接口、网站与设置模型
  ComponentDetector.swift           Homebrew 路径发现及 Mach-O 检测
  PortableRuntime.swift             应用内运行时清单、布局、完整性检查与优先解析
  SettingsStore.swift               配置读取、校验和原子保存
  WebsiteHosting.swift              网站目录安全校验与真实端口占用检测
  ServiceReconfiguration.swift      设置保存编排：变更分类、操作闸门、停服与回滚顺序
  HtaccessPreflight.swift           .htaccess 预检：求值 IfModule 条件并分类报告
  WebStack.swift                    模块加载计划、组件解析、配置生成及语法检查
  LocalWebStackController.swift     Web 进程启停、健康检查与回滚
  DatabaseStack.swift               MariaDB 初始化、配置、查询与正常关闭
  DatabaseBackup.swift              业务库列表、流式 SQL 导出与恢复
  DatabaseRestore.swift             大 SQL 空间预检、进度与取消
  BackupCatalog.swift               备份历史和自动备份目录
  DatabaseCredentialStore.swift     不弹交互授权的钥匙串凭据读写
  PHPMyAdmin.swift                  独立复制、cookie 配置与版本保护
  XAMPPMigration.swift             旧 XAMPP 只读盘点与脱敏报告
  WebsiteMigration.swift          网站副本预览、复制、校验与回滚
  LegacyDatabaseMigration.swift     旧数据库逻辑导出连接
  ProjectCreator.swift              PHP 项目骨架与 PDO 模板
  TLSCertificate.swift              本地 HTTPS 证书生成与信任
  ServiceIntentStore.swift          服务运行意图持久化
  ResidualServiceRecovery.swift     强退残留身份核对与清理
  LogMaintenance.swift              日志轮转
  DeveloperTools.swift              PHP 扩展和工具检测
  PHPExtensions.swift               私有扩展清单、安装、启停、校验、备份与恢复
  HomebrewDependencies.swift        白名单依赖检测与显式安装
Sources/MacStackApp/
  MacStackApp.swift                  应用入口
  AppVersion.swift                   版本号唯一来源（读 Info.plist）
  AppModel.swift                     核心状态、启动流程、组件检测
  AppModel+Services.swift            开发者工具、PHP 扩展、依赖、Web/数据库启停
  AppModel+Settings.swift            设置应用、状态刷新、服务巡检与备份调度
  AppModel+Backups.swift             数据库列表、导出、恢复、自动备份与保留策略
  AppModel+Websites.swift            保存预设、网站增删改、证书与 Finder 入口
  AppModel+Database.swift            phpMyAdmin、数据库凭据、建库、PDO 模板
  AppModel+Migration.swift           旧 XAMPP 盘点、网站与旧库迁移
  ContentView.swift                  导航骨架（页面在 Pages/ 下）
  Pages/                             八个页面 + 共用的 PageHeading
  Sheets/                            编辑网站、创建项目、迁移旧数据库
Sources/MacStackCLI/main.swift      准备配置和冒烟测试命令
Tests/MacStackCoreTests/CoreTests.swift
Resources/Info.plist                 应用包元数据与图标声明
Resources/MacStack.icns              Finder、Dock 与应用切换器使用的 macOS 图标
Resources/MacStackIcon-1024.png      应用图标的 1024 px 主图
scripts/build-app.sh                编译、打包、本地签名
scripts/build-portable-runtime.sh   收集、迁移并校验 ARM64 服务运行时
scripts/collect-runtime-licenses.sh 按组件收集许可证与声明文件，生成 THIRD-PARTY.md
scripts/license_manifest.py         生成许可证清单并为缺文件的组件补 SPDX 正文
scripts/refresh-license-texts.sh    手动刷新 vendor/spdx（发行构建不联网）
scripts/verify-portable-runtime.sh  只读检查运行时架构、动态库引用与许可证覆盖
scripts/package-release.sh          DMG/ZIP/校验和及可选签名公证
scripts/test.sh                     选择工具链并运行测试
scripts/swift-env.sh                当前进程工具链选择
vendor/spdx/                        固定版本的 SPDX 许可证正文与 SHA-256 清单
docs/NEXT_STEPS.md                   后续实现顺序与验收条件
docs/IMPROVEMENT_PLAN.md             分阶段改进方案与实施状态
```

## 服务与权限约定

MacStack 复用 ARM64 开源组件，并传入独立配置、日志和运行目录管理自身进程。
Homebrew 只提供组件，不同时通过 brew services 管理同一实例。
默认 HTTP 8080、数据库 3307、只监听本机。数据库停止必须正常关闭。
不能按进程名称批量杀死服务；需要验证进程身份、配置路径及所有权。
控制器保存它直接启动的 `Process` 对象，只终止这些对象，不搜索或批量杀死同名进程。项目没有新增管理员权限规则、登录项目、后台服务或系统证书。

## 开发进度

0.10.0 已完成首版免 Homebrew 发行运行时：应用内优先解析、Apache/PHP/MariaDB/phpMyAdmin 资源路径、递归 dylib 迁移、嵌入打包及隔离运行测试。下一阶段集中在签名更新清单与自动回滚、受限的可选 FTP 服务、从上游源码完全可复现构建，以及更多真实项目兼容性；具体见 `docs/NEXT_STEPS.md`。

## 本机验证记录（2026-09-14）

### 改进方案五个阶段实施后的完整回归

- `swift test --disable-sandbox`：**72 项全部通过**，编译无警告。（`--disable-sandbox` 是必须的：SwiftPM 默认用 `sandbox-exec` 编译 manifest，在受限环境下会报 `sandbox_apply: Operation not permitted`。）
- **10 条验收命令全部通过**：`prepare`、`smoke-test`、`sites-smoke-test`、`htaccess-smoke-test`、`prepare-database`、`database-smoke-test`、`database-backup-smoke-test`、`prepare-phpmyadmin`、`full-smoke-test`、`audit-xampp`。
- **配置迁移验证**：旧 `httpd.conf` 里不含任何新配置（`grep` 计数为 0），运行 `prepare` 后重新生成，确认包含 8 个 `.htaccess` 必需模块、`AllowOverride FileInfo Indexes AuthConfig Limit`（默认站点与登记网站）与 `AllowOverride None`（内部健康检查）、`Options -Indexes -FollowSymLinks +SymLinksIfOwnerMatch`，`php.ini` 的 `date.timezone` 由硬编码 UTC 变为系统时区 `Asia/Shanghai`，并写入 `memory_limit` / `upload_max_filesize` / `post_max_size`。
- **发现并修复一处数据完整性缺陷（非本次改动引入）**：`database-backup-smoke-test` 首次运行失败，中文数据恢复后变成乱码（`动态内容` → `Ŋ�ƀ�ņ�Ů�`）。根因是字符集不对称——导出侧（`mariadb-dump`）指定了 `--default-character-set=utf8mb4`，而导入、查询、执行 SQL 三处沿用客户端默认字符集。三处参数当时各写一份，漏了谁都看不出来。已抽出 `DatabaseClientArguments` 作为单一来源并补上字符集，重跑通过。这意味着**此前任何含非 ASCII 内容的备份在恢复后都可能损坏**，修复前生成的备份建议重新导出。
- 上一条的**两条恢复路径都已验证**：`DatabaseBackupManager.restoreBackup`（普通恢复）与 `DatabaseRestoreJob`（GUI 恢复大 SQL 用的流式路径）。后者有自己一份命令行参数，正是当初漏掉字符集的地方，因此 `database-backup-smoke-test` 现在会对同一个含中文、视图和触发器的临时库跑两遍恢复并各自校验。
- **修复 `scripts/swift-env.sh` 未导出 `BUILD_CACHE`**：该脚本注释写明「编译缓存要放在非同步目录，避免 Documents 文件提供器给测试包附加 FinderInfo 导致签名失败」，但变量没有 `export`。调用方用 `bash -c` 启动子进程时读到空值，SwiftPM 退回 `$PWD/out`，把产物建回 Documents 下，于是测试包的 codesign 步骤真的失败了（`MacStackCoreTests.xctest failed with a nonzero exit code`）。已加 `export`。项目根下的 `out/` 目录就是这么来的，已在 `.gitignore` 中忽略。
- **`htaccess-smoke-test` 扩展了两项真实场景检查**：
  - **框架兼容**：Laravel / Symfony 官方 `.htaccess` 的写法（`<IfModule mod_rewrite.c>` 内嵌 `<IfModule mod_negotiation.c>` 再写 `Options -MultiViews -Indexes`）返回 HTTP 200。它能工作是因为 mod_negotiation 未加载、内层整块被 Apache 跳过——这也正是预检必须求值 `IfModule` 而不能一刀切的原因。
  - **覆盖类检查**：裸 `Options -MultiViews -Indexes`（不在会被跳过的 `IfModule` 里）实测会让站点返回 **HTTP 500**，因为默认的 `AllowOverride FileInfo Indexes AuthConfig Limit` 不含 `Options`。此前预检只查 `php_value` 和模块依赖，**完全漏掉这一类**；现已补上 `overrideNotPermitted` 判定（阻塞级），并给出可执行出路——在设置页开启「允许 .htaccess 覆盖 Options」，开启后放行。
- 便携运行时许可证收集：`licenses/` 由 0 个文件、63 个空目录变为 **161 个文件、0 个空目录**（1.5 MB），含 59 个 Homebrew SPDX SBOM；`verify-portable-runtime.sh` 增加逐组件校验。
- 构建脚本的 `mime.types` 搬运步骤已实测：源文件 `apache/.bottle/etc/httpd/mime.types`（61109 字节）存在，可正确搬到 `apache/etc/httpd/mime.types`。源码开发环境下 `TypesConfig` 仍回退系统路径，因为 Homebrew 的 httpd keg 里没有这个文件；发布包会使用运行时自带副本（有单元测试覆盖该分支）。

### 0.10.0 便携运行时首版

- 0.10.0 便携运行时大小约 474 MB；290 个 Mach-O 文件均验证为 ARM64，`otool -L` 未发现 `/opt/homebrew` 或 `/usr/local` 动态库引用。
- 在仅含系统目录的 PATH 下，便携 Apache 2.4.68、PHP/PHP-FPM 8.2.33、MariaDB 服务端与客户端 11.4.13 均能直接运行。
- 从最终 `MacStack.app/Contents/Resources/runtime` 运行 33 项测试全部通过，包含真实 PHP HTTP 健康检查，以及临时 MariaDB 数据目录初始化、查询与正常关闭；未改动现有用户数据库。
- 本机新增 Homebrew 官方 ARM64 `httpd 2.4.68`、`php@8.2 8.2.33` 及依赖；没有运行 `brew services`，没有升级其他已安装公式。
- 新增 keg-only ARM64 `mariadb@11.4 11.4.13`，因已有 MySQL 9.6 未做全局链接，MacStack 使用绝对路径；没有取消链接或修改原 MySQL 数据目录。
- 新增 `phpmyadmin 5.2.3`，复制到 MacStack runtime 后生成自己的配置；Homebrew 原配置未修改。
- 因旧 Homebrew 不识别当前 PHP 配方步骤，仅把 Homebrew 自身从 6.0.2 更新到 6.0.22；已列出的 11 个旧公式和 4 个旧应用未升级。
- `bash scripts/test.sh`：30 项核心与本机集成测试通过；包括真实 HTTPS 和 Perl/CGI 请求、PHP 私有扩展启停/备份恢复、项目创建、备份目录、SQL 空间预检、服务意图和日志轮转。
- `bash scripts/build-app.sh`：Release 构建、Info.plist 校验和本地签名验证通过。
- `file dist/MacStack.app/Contents/MacOS/MacStack`：Mach-O 64-bit executable arm64；当前管理应用不需要 Rosetta。
- `macstackctl smoke-test`：Apache → PHP-FPM → 独立内部端点返回健康标记与 PHP 8.2.33；用户 `index.php` 不参与启动判断，重复启动未创建第二套进程，随后正常停止。
- 端口占用测试：预先占用 127.0.0.1:8080 后，Apache 明确报错，控制器回滚自己启动的 PHP-FPM，不影响占用端口的测试进程。
- `database-smoke-test`：独立数据目录执行 `SELECT VERSION()` 返回 11.4.13-MariaDB，并通过管理客户端正常关闭；第二次准备没有重新初始化。
- `database-backup-smoke-test`：创建临时业务库并写入中文数据、视图和触发器；导出后删除数据库，再从 SQL 恢复并逐项查询验证，最后清理临时库和备份。
- 数据库端口占用测试：预先占用 127.0.0.1:3307 后 MariaDB 明确失败，没有残留数据库进程，也未影响占用者。
- `full-smoke-test`：PHP 8.2 + MariaDB 11.4.13 + phpMyAdmin 登录页 HTTP 200，随后三个服务全部正常停止。
- `sites-smoke-test`：两个真实站点分别在 18081/18082 提供 PHP 动态页和静态 HTML/CSS；`.env` 与 `.git/config` 均返回 403；停用 PHP 站点并重启后静态站点仍可访问且端口不变。
- `htaccess-smoke-test`（2026-09-14 新增）：真实启动 Apache 验证 `.htaccess` 支持。站点 `.htaccess` 用 `RewriteRule ^pretty/([0-9]+)$ index.php?id=$1`，`/pretty/42` 返回 HTTP 200 且正文为 `REWRITE-OK-42`，证明 mod_rewrite 与 `AllowOverride FileInfo Indexes AuthConfig Limit` 生效；对照组 `/pretty/abc` 返回 404，证明确实走了重写而非兜底路由；`.env` 与 `.git/config` 返回 403；关闭 `allowHtaccess` 后同一份 `.htaccess` 的 `/pretty/42` 变为 404，证明开关生效；顶层 `php_value` 在准备阶段被拒绝；`IndexOptions` 在未加载 autoindex 时给出提示、开启后提示消失。
- 多站点端口冲突：占用待用站点端口后 Apache 明确拒绝启动，MacStack 回滚自己的进程，外部占用者保持运行。
- `audit-xampp`：真实扫描 `/Applications/XAMPP`，可统计 915.8 MB；发现网站候选 `mystudy`（28 bytes、1 个 PHP 文件）、4 个系统数据库目录、0 个明显业务数据库。旧 Apache/PHP/MySQL 主程序均为 x86_64。盘点前后 `httpd.conf` 与 `mystudy/index.php` SHA-256 相同。
- 0.10.0（build 14）已安装到 `~/Applications/MacStack.app`；arm64 架构、ad-hoc 签名和新应用图标均已核验，应用进程可正常保持运行。自动界面检查仍因本机 UI 控制通道中断而未完成，不能用进程存在代替完整点击验收。
- 0.10.0 便携运行时的 DMG/ZIP 已通过 `hdiutil verify`、SHA-256、ARM64 架构和外部 Homebrew 动态库引用检查；未使用 Developer ID 公证，因此当前仍属于开发预览包。

手动界面验收待办：逐页查看布局；在 PHP 扩展页点击启用/停用一个已安装动态扩展并观察状态；从应用点击生成、启动、停止、复制密码和打开 phpMyAdmin；登记并启用真实网站、编辑公开目录和端口、重开应用检查保存；移出清单后确认目录仍存在。
