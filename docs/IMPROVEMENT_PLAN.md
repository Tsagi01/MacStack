# MacStack 改进方案（v3）

依据：对 `Sources/MacStackCore`（24 个文件）、`Sources/MacStackApp`、`Sources/MacStackCLI`、`Tests`、`scripts/`、`docs/` 的通读，加上对 `runtime/stage/` 的实测，以及随包 Apache 2.4.68 官方手册（`runtime/stage/apache/share/httpd/manual/`）的原文核对。

**修订历史**：v1 的 Web 配置方案有设计矛盾；v2 修正了配置方向但引入了若干过度概括；v3 修正 v2 的细节错误。每处修订都标注了验证来源，修订对照见附录 A。

本方案只做「修复与加固」，不改变项目既有设计原则：不做隐式安装、不按名称批量杀进程、不删除用户旧环境、配置改动先校验后替换。

## 实施状态（2026-09-14）

| 阶段 | 状态 | 说明 |
|---|---|---|
| 零 | **完成** | `.gitignore` 补齐并验证；仓库已建立，边界为 MacStack 自身（`git rev-parse --show-toplevel` 指向 `MacStack/`，不再受父仓库影响），分支 `main`，公开远程为 `https://github.com/Tsagi01/MacStack`。 |
| 一 | **代码完成，待人工验收** | 新增 `ServiceReconfiguration.swift`（编排 + `PreferenceChanges` + `OperationGate`），`AppModel` 与 `ContentView` 已接线。界面手工验收项见 1.5。 |
| 二 | **完成（含端到端验证）** | 新增 `HtaccessPreflight.swift`；`WebStack.swift` 完成模块加载、Options/AllowOverride、php.ini、TypesConfig、phpMyAdmin 一致性；`Models.swift` 新增 7 个偏好项与校验；构建脚本搬运 `mime.types`。**新增 `macstackctl htaccess-smoke-test` 并已实跑通过**，见下方。 |
| 三 | **代码完成，待正式合规审核** | 新增 `scripts/collect-runtime-licenses.sh` + `license_manifest.py` + `refresh-license-texts.sh`，`vendor/spdx/` 固化 `v3.28.0` 的 3 个许可证正文与 SHA-256。实测：许可证文件从 **0 → 161 个**，63 个组件目录**无一为空**，59 个 SBOM 已归集。`verify-portable-runtime.sh` 增加逐组件校验。README 与 `NEXT_STEPS.md` 的不准确表述已更正。 |
| 四 | **完成** | 6 项全部落地：`CommandOutput` 字段改名（删掉恒为空的 `standardError`）、备份计数改用任务返回值、按库判断备份间隔、自动备份保留策略、日志轮转时机对齐句柄生命周期、残留进程恢复不中断 + 进程身份复核。新增 6 项测试。 |
| 五 | **完成（本地化除外，已说明原因）** | 5.1 拆分完成（`AppModel` 1506 → 7 个文件，最大 414 行；`ContentView` 993 → 71 行 + 9 个页面文件 + 3 个 sheet 文件）；5.2 版本号改为从 Info.plist 读取；5.4 新增 12 个 `#Preview`；5.3 本地化经实测评估后**决定不做**，理由见 5.3。 |

当前测试：**72 项全部通过**。阶段四用沙箱外执行复跑后，之前那个「环境性失败」的 `databaseCredentialKeychainRoundTrip` 也通过了——证实它确实只是沙箱阻止钥匙串写入，代码本身没有问题。编译无警告。

阶段一未决事项：`ContentView` 第 769 行原本就在服务运行时禁用「保存预设」，因此 A 类「停服 → 持久化 → 失效控制器」路径目前无法从界面触发。模型层已能安全处理，是否放开该按钮由界面层决定。

阶段二待补：~~端到端用例（`sites-smoke-test` 里放带 `RewriteRule` 的 `.htaccess` 断言伪静态返回 200）与站点 500 检测~~ —— **已完成**。新增 `macstackctl htaccess-smoke-test`，2026-09-14 实跑通过：

```
伪静态检查通过：/pretty/42 → HTTP 200 且内容为 REWRITE-OK-42（mod_rewrite + AllowOverride 生效）。
对照组通过：不匹配规则的 /pretty/abc 返回 404。
敏感文件拦截通过：.env 与 .git/config 均返回 403。
开关检查通过：关闭 .htaccess 支持后 /pretty/42 返回 404。
php_value 检查通过：顶层 php_value 在准备阶段被拒绝，不会生成必然 500 的配置。
可选模块检查通过：IndexOptions 在未加载 autoindex 时给出提示，开启后提示消失。
```

对照组（`/pretty/abc` → 404）是必要的：只断言 `/pretty/42` 返回 200 无法区分「重写生效」和「兜底路由」。剩下的「站点返回 500 时界面标注」属于界面行为，仍需人工点击验证。

阶段三待补：**合规结论本身**。随包提供声明与正文不等于合规——MariaDB 的 `GPL-2.0-only`、PHP 表达式里的 LGPL 条款、以及 Homebrew 的 `LicenseRef-*` 标识符仍需正式审核，清单见 `licenses/THIRD-PARTY.md` 末尾。

### 附：验收套件跑出来的一个既有缺陷（方案外，已修）

实施完成后跑完整验收套件时，`database-backup-smoke-test` 失败：中文数据恢复后变成乱码（`动态内容` → `Ŋ�ƀ�ņ�Ů�`）。

**不是本次改动引入的**——用阶段一前的快照对比确认，`DatabaseBackup.swift` 只有字段改名，无行为变化。根因是**字符集不对称**：

- 导出侧 `exportDatabase` 显式传了 `--default-character-set=utf8mb4`
- 导入（`restoreBackup`）、查询（`query`）、执行 SQL（`executeSQL`）三处共用的 `clientArguments` **完全没有字符集参数**
- 导出写 utf8mb4 字节、导入用客户端默认字符集解释 → 往返后损坏

`DatabaseRestore.swift`（大 SQL 流式恢复）和 `DatabaseStack.swift` 有同样问题。三处参数各写一份，漏了谁都看不出来。

已抽出 `DatabaseClientArguments` 作为单一来源，并补了单元测试锁住「公共参数必须带字符集」这条不变量。修复后重跑通过。

**影响**：修复前，任何含非 ASCII 内容的备份在恢复后都可能损坏——这对一个用来托管 WordPress 之类项目的工具是严重问题。这也说明**只跑单元测试不够**：这个缺陷在 65 项单元测试里完全看不出来，只有真实跑一遍 MariaDB 往返才会暴露。

**教训**：多个模块各自拼装同一组命令行参数时，应该抽成单一来源，否则一致性靠人记，迟早漏。

**补充：两条恢复路径都已覆盖。** `DatabaseBackupManager.restoreBackup` 与 `DatabaseRestoreJob`（GUI 恢复大 SQL 用的流式路径）各有一份命令行参数，后者正是当初漏掉字符集的地方。`database-backup-smoke-test` 现在对同一个含中文、视图和触发器的临时库跑两遍恢复（先普通、后流式）并各自校验，避免只覆盖其中一条。

**顺带修掉的第二个环境缺陷**：`scripts/swift-env.sh` 设置了 `BUILD_CACHE` 却没 `export`。该脚本注释写明「编译缓存要放在非同步目录，避免 Documents 文件提供器给测试包附加 FinderInfo 导致签名失败」，但子进程读到的是空值 → SwiftPM 退回 `$PWD/out` → 产物建回 Documents → 测试包 codesign 真的失败。已加 `export`。项目根下的 `out/`（本次运行后已达 231 MB）就是这么产生的。

### 附：预检漏判覆盖类（阶段二的缺口，实施后补上）

阶段二完成后，为了验证「预检会不会误判真实项目的 `.htaccess`」，往 `htaccess-smoke-test` 里加了一个 Laravel / Symfony 官方写法的 fixture。它通过了——但**原因值得深究**：`Options -MultiViews -Indexes` 被包在 `<IfModule mod_negotiation.c>` 里，而该模块未加载，Apache 整块跳过。

于是反过来测「裸 `Options`」，结果：

```
Laravel / Symfony 风格的 .htaccess 让站点返回 HTTP 500（应为 200）。
预检结果：（无发现）
```

**实测确认**：默认的 `AllowOverride FileInfo Indexes AuthConfig Limit` 不含 `Options`，裸 `Options` 必然 500，而 v3 的预检只查 `php_value` 和模块依赖，**完全漏掉这一类**。

已补 `overrideNotPermitted` 判定（阻塞级，覆盖 `Options` 与 `XBitHack`），并在提示里给出可执行出路。同时确认必须**求值 `IfModule` 后再判断**——否则会把标准框架项目误判成不能启用。

`htaccess-smoke-test` 现在共 8 项检查，其中两项专门覆盖这一对相反场景（框架写法放行、裸 Options 拦下）。

---

## 0. 优先级总览

| 阶段 | 主题 | 性质 | 改动面 |
|---|---|---|---|
| 零 | 仓库边界与基线 | 前置条件 | 仓库操作 |
| 一 | 服务控制权安全 | 安全缺陷 | `AppModel.swift` + `ContentView.swift` |
| 二 | Web 配置兼容性 | 功能缺陷 | `WebStack.swift` + `Models.swift` + `WebsiteHosting.swift` |
| 三 | 许可证合规 | 发布门槛 | `build-portable-runtime.sh` |
| 四 | 健壮性小修 | 数据正确性 | 分散 6 个文件 |
| 五 | 工程结构与本地化 | 长期维护 | 大范围重构 |

---

## 阶段零：仓库边界与基线

### 0.1 现状（已实测）

`MacStack/` 位于父仓库 `Documents/Playground` 内，父仓库已有 `.git` 但零提交，`MacStack/` 完全未被跟踪：

```
$ git rev-parse --show-toplevel   → ~/Documents/Playground
$ git rev-list --count --all      → 0
$ git ls-files MacStack | wc -l   → 0
```

父仓库没有 `.gitignore`，13 个未跟踪顶层条目里混着 8 个不相关项目、`.idea/`、`.DS_Store` 和一个 zip。

### 0.2 初始化前必须补齐忽略规则

**v2 遗漏**：只说了「`.gitignore` 已正确忽略 `runtime/stage/`、`dist/`、`.build/`」，没有核查其余构建产物。实测顶层目录体积：

```
474M  runtime      ← 仅 build/stage/downloads 被忽略，其余需确认
297M  dist/        ← 已忽略
236M  .build/      ← 已忽略
 76M  out/         ← 未忽略
 4.0K workspace-state.json   ← 未忽略
 4.0K .lock                  ← 未忽略
   0B {{pkgetc}}              ← 未忽略，且是未展开变量留下的字面目录名
   0B repositories/ checkouts/ artifacts/ debug/   ← 未忽略
```

当前 `.gitignore` 只有 7 行：

```
.build/  .swiftpm/  dist/  runtime/build/  runtime/stage/  runtime/downloads/  .DS_Store
```

`git add -A` 的 dry-run 条目数是 **1570**，其中包含整个 76 MB 的 `out/`。

初始化步骤：

1. 补齐 `.gitignore`：加入 `out/`、`workspace-state.json`、`.lock`、`{{pkgetc}}`、`repositories/`、`checkouts/`、`artifacts/`、`debug/`
2. 逐个确认 `runtime/` 下哪些要跟踪（`manifest.template.json` 应该跟踪，其余目录应忽略）
3. `git init` 后**先跑 `git add -A --dry-run` 检查暂存清单**，确认无构建产物、无二进制、无 `.DS_Store`，再真正提交
4. 提交后用 `git count-objects -vH` 确认仓库体积在合理范围（应为数百 KB 级，不是数百 MB）

### 0.3 独立仓库

只把 MacStack 建成独立仓库并推送到 GitHub。父仓库的状态（零提交、无 `.gitignore`、多项目混杂）单独处理，**不纳入本方案范围**。

**实施结果**：仓库已建立，`git rev-parse --show-toplevel` 现在指向 `MacStack/` 自身，边界正确。分支 `main`，72 个文件、12555 行，工作区干净。

两点需要记录：

1. **只有一个提交，没有独立的「改进前基线」。** 因为执行环境长期阻止 `.git` 写入（见下），基线提交一直做不了；等到绕过之后，工作区已经是五个阶段改完的状态。因此这一个提交同时包含改进前后的内容。改进前的源码快照保存在 `~/Library/Caches/MacStack/pre-stage1-20260914-150830/`（仅 `Sources/`、`Tests/`、`docs/`、`Package.swift`、`.gitignore`）。
2. **公开仓库身份已改为 GitHub noreply 地址**（仅仓库级，不修改全局 Git 配置），远程使用 HTTPS：

```sh
git remote -v
git push origin main
```

**绕过 `.git` 写入限制的办法**（供以后在受限环境里参考）：环境只阻止 `git init` 自己从零创建 `.git/config`，但允许复制一个现成的 `.git` 目录。因此可以先在临时目录 `git init`，再 `cp -R <tmp>/.git ./.git`，之后 `git add` / `commit` / `config` 全部正常。

### 0.4 基线验证

提交前跑一次测试，记录结果作为后续改动的对照基准。

**实测结果（2026-09-14）**：33 项测试，**32 通过、1 失败**。失败项是 `databaseCredentialKeychainRoundTrip`，报 `Caught error: .keychain(100001)`。原因是执行环境阻止了钥匙串写入（`~/Library/Keychains/login.keychain-db` 被沙箱拒绝），属于环境限制，不是项目缺陷——在正常终端下应能通过。提交基线前建议在普通终端复跑一次确认。

**运行测试需要 `--disable-sandbox`**：`swift test` 默认会让 SwiftPM 用 `sandbox-exec` 编译 manifest，在受限环境下会报 `sandbox_apply: Operation not permitted`。可用：

```sh
source scripts/swift-env.sh
swift test --disable-sandbox --scratch-path "$BUILD_CACHE"
```

**注意**：如果 `git init` 在当前执行环境中被拒绝（`.git/config` 写入受限），需要在普通终端里执行阶段零的仓库操作。

---

## 阶段一：服务控制权安全

> 本方案里唯一的「安全缺陷」级问题，改动局部，最先修。

### 1.1 问题

`AppModel.save(_:)`（`AppModel.swift` 第 975 行）在预设变化时执行 `webController = nil` / `databaseController = nil`，但**不先停服务**。之后：

- `stopWebServices()` 第 370 行 `guard let webController else { webServicesRunning = false; return }` 直接返回，进程停不掉
- `stopAllServicesForTermination()` 第 470 行同样失效
- 结果：Apache / PHP-FPM / MariaDB 继续运行，应用失去控制权，界面仍显示「运行中」

### 1.2 并发控制（v2 遗漏）

**v2 遗漏**：只把 `save` 改成 `async`，没有考虑 `async` 引入的重入问题。每个 `await` 都是一个挂起点，期间用户可以再次点「保存预设」、点「启动」、或触发备份恢复。`changingWebServices` 这类已有标志各自只管一个子系统，没有任何一个覆盖整个保存过程。

需要新增一个覆盖全程的状态锁：

```swift
@Published private var savingSettings = false
```

并把它纳入 `hasCriticalOperation`（第 70 行）：

```swift
var hasCriticalOperation: Bool {
    savingSettings || restoringDatabase || backingUpDatabase || migratingLegacyDatabase != nil
        || creatingProject || installingDependencies || changingPHPExtension != nil
}
```

### 1.2.1 锁必须接入每个操作入口

**仅把 `savingSettings` 加进 `hasCriticalOperation` 不会自动阻止任何操作。** `hasCriticalOperation` 目前只被退出流程读取（判断能否安全退出），它不是一个互斥闸门。启动、保存、备份这些方法各有自己的 guard，必须逐个接入，否则锁形同虚设。

需要检查并修改的**方法入口**：

| 方法 | 现有 guard | 追加 |
|---|---|---|
| `save(_:)` | `canSave` | `!savingSettings` |
| `startWebServices` / `stopWebServices` | `!changingWebServices` | `!savingSettings` |
| `startDatabase` / `stopDatabase` | `!changingDatabase` | `!savingSettings` |
| `startAllServices` / `stopAllServices` | `!changingAllServices` | `!savingSettings` |
| `applyWebsiteSettings` | `changingWebsiteID == nil, !changingWebServices` | `!savingSettings` |
| `restoreDatabaseBackup` / `runAutomaticBackupNow` | 各自状态位 | `!savingSettings` |
| `prepareWebEnvironment` / `prepareDatabaseEnvironment` | `!preparingWebStack` / `!preparingDatabase` | 见下方例外说明 |

**例外：内部受控重启必须允许执行。** `save` 在处理 B 类变更时需要调用「重新生成配置 → 重启」的流程，如果那套流程也去检查 `savingSettings`，就会自己把自己挡住。做法是把内部实现抽成不带锁检查的私有方法（如 `regenerateWebConfigurationUnlocked(...)`），公开入口 `prepareWebEnvironment()` 负责检查锁并调用它。这样外部调用被挡住，内部流程畅通。

**UI 入口**同样要接入，否则用户能点到被拒绝的操作，只能看到一个含糊的提示：

| 控件 | 位置 | 处理 |
|---|---|---|
| 「保存预设」 | `ContentView.swift` 第 751 行 | `savingSettings` 时禁用 |
| Start All / Stop All | 第 105、109 行 | 同上 |
| Web 环境的「生成并校验配置」「启动」「停止」 | 第 126、137、140 行 | 同上 |
| 数据库的「准备」「启动」「停止」 | 第 248、251、254 行 | 同上 |
| 「立即备份全部数据库」「恢复 SQL 备份…」 | 第 341、319 行 | 同上 |

另外 `save` 变 `async` 后，第 768 行的调用要改成 `Task { await model.save(next) }`。

### 1.3 校验顺序：先验后停

必须先校验新设置，**再**停服务。否则一个非法端口（比如和数据库端口冲突）会导致服务被白停一次，然后保存失败——用户看到的是「服务被停了但设置没保存」。

```swift
func save(_ next: WorkspaceSettings) async {
    guard canSave, !savingSettings else { return }
    do { try next.validate() } catch {
        message = "设置未保存：\(error.localizedDescription)"
        return
    }

    let changes = PreferenceChanges(from: settings.preferences, to: next.preferences)
    guard changes.requiresServiceStop || changes.requiresConfigRegeneration else {
        persist(next, reconfiguring: false)
        return
    }

    savingSettings = true
    defer { savingSettings = false }

    guard !changingWebServices, !changingDatabase, !changingAllServices else {
        message = "服务正在切换状态，请稍候再保存预设。"
        return
    }
    if restoringDatabase || backingUpDatabase {
        message = "备份或恢复正在进行，请完成后再保存预设。"
        return
    }
    // ... 停服务 → 重新生成配置 → 持久化
}
```

### 1.4 两类变更要分开处理（v2 遗漏）

**v2 遗漏**：把「重新配置」当成一件事，一律置空控制器。实际上有两类，处理方式不同：

| 类别 | 包含的偏好项 | 处理 |
|---|---|---|
| **A 类：使控制器失效** | `httpPort`、`databasePort`、`preferredPHPFormula`、`httpsEnabled`、`httpsPort`、`perlCGIEnabled` | 停服务 → 置空控制器 → 下次使用时重新 prepare |
| **B 类：只需重新生成配置** | `phpTimezone`、`uploadMaxFilesizeMB`、`postMaxSizeMB`、`memoryLimitMB`、`allowHtaccess`、`allowHtaccessOptions`、可选模块开关 | 停服务 → 用**新设置**重新生成配置 → 受控重启 |

B 类走 A 类的路径会白白丢掉进程句柄，且完全没有必要。

**注意**：v2 新增的时区、上传限制、`.htaccess` 开关**必须**纳入这个判断。如果漏掉，用户改了上传限制却看不到任何效果，因为配置根本没重新生成。

**实施顺序上的依赖**：截至当前代码，影响 Web 配置的现有偏好项（`httpPort`、`httpsEnabled`、`httpsPort`、`perlCGIEnabled`、`preferredPHPFormula`）**全部属于 A 类**——B 类里那些偏好项（`phpTimezone`、上传/内存限制、`allowHtaccess` 等）是阶段二才引入的，现在还不存在。

所以阶段一的正确交付范围是：

- **A 类路径完整修好**（这才是当前实际存在的安全缺陷）
- **B 类的分类框架和回滚路径一并搭好**，但暂时没有偏好项会走到它
- 阶段二引入新偏好项后，B 类路径自然被激活，届时按 1.5.1 的测试表补齐 B 类用例

不要为了「让 B 类有东西可测」而在阶段一提前引入阶段二的偏好项——那会把两个阶段的风险混在一起。

### 1.4.1 B 类不能复用现有 `prepareWebEnvironment()`

现有实现（第 321 行）不能直接用于 B 类，两个原因：

```swift
func prepareWebEnvironment() async {
    guard !preparingWebStack else { return }
    preparingWebStack = true
    let preferences = settings.preferences   // ← ① 读的是旧的 settings，不是新设置
    ...
    webController = LocalWebStackController(installation: prepared.installation, layout: prepared.layout)  // ← ② 直接创建新控制器
    ...
    } catch {
        message = error.localizedDescription
        webStackStatus = "准备失败：\(error.localizedDescription)"   // ← ③ 失败只报错，不恢复旧配置和原运行状态
    }
}
```

① 它读 `settings.preferences`（旧的 `@Published` 属性），B 类要生效的恰恰是尚未写入的 `next.preferences`；
② 它无条件创建新控制器；
③ 失败时既不恢复磁盘上的旧配置，也不恢复原来的运行状态。

**做法**：新增一个显式接收设置的私有方法，参照 `applyWebsiteSettings`（第 1152 行）已验证的回滚模式：

```swift
private func regenerateWebConfiguration(
    preferences: Preferences,
    websites: [Website],
    wasRunning: Bool
) async throws {
    let prepared = try await Task.detached {
        let installation = try WebStackResolver(preferredFormula: preferences.preferredPHPFormula).resolve()
        return try WebStackPreparer().prepare(
            installation: installation, preferences: preferences, websites: websites
        )
    }.value
    let controller = LocalWebStackController(installation: prepared.installation, layout: prepared.layout)
    if wasRunning { try await controller.startWebStack(httpPort: preferences.httpPort) }
    webController = controller          // 只在成功后替换，期间始终非 nil
    webServicesRunning = wasRunning
}
```

`save` 的 B 类分支：保存 `previous` 与 `wasRunning` → 停服 → 调用上述方法 → 持久化；失败时用 `previous` 重新生成并恢复原运行状态（与 `applyWebsiteSettings` 第 1183–1217 行的恢复逻辑一致）。

**关于控制器复用**：不要求复用同一个控制器对象。`applyWebsiteSettings` 实际上也是每次都创建新控制器（第 1174 行的 `nextController`），只要**替换过程中控制器始终非 nil、进程句柄不丢**就满足要求。真正要避免的是 v2 那种「先置 nil 再停服」的顺序。

### 1.5 验收

手工验收：

- 启动 Web + 数据库 → 设置页改 HTTP 端口 → 保存：服务被正常停止、状态变为「已停止」，预设保存成功
- `lsof -iTCP:8080 -sTCP:LISTEN` 确认无残留监听进程
- 改上传限制（B 类）→ 保存：服务受控重启，**控制器不丢**，`php.ini` 里能看到新值
- 保存过程中连点两次「保存预设」→ 第二次被拒绝，不产生并发写入
- 保存过程中点「启动 Web 环境」→ 被拒绝并给出提示
- 输入与数据库端口冲突的 HTTP 端口 → 保存失败且**服务未被停止**

### 1.5.1 测试基础设施必须在阶段一就位

上面三条状态测试（重复保存、保存期间启动、配置失败回滚）**是本次修复的验收条件**，不能推到阶段五。但当前结构不支持：`MacStackCoreTests` 只依赖 `MacStackCore`，而 `save` 的逻辑在 `MacStackApp`（可执行目标）里，且 `AppModel` 直接持有具体的 `LocalWebStackController` actor，没有注入点。

最小改动即可解决，不需要等阶段五的重构：

1. **在 `MacStackCore` 里定义控制协议**，`LocalWebStackController` 已有的方法正好覆盖，只需补一行 conformance：

```swift
public protocol WebStackControlling: Sendable {
    func startWebStack(httpPort: Int) async throws
    func stopWebStack() async throws
    func state(of component: Component) async -> ServiceState
}
```

2. **把编排逻辑下沉到 `MacStackCore`**：新增 `ServiceReconfiguration`，显式接收「旧设置 / 新设置 / 控制器工厂」，把「校验 → 分类 → 停服 → 重新生成 → 重启 → 失败回滚」这套状态机放在这里。它只依赖上面的协议和闭包，可以在 `MacStackCoreTests` 里用假实现完整驱动。
3. `AppModel.save` 退化成薄适配层：加锁、调用 `ServiceReconfiguration`、更新界面状态。

这样测试覆盖的是真实的状态机，而不是对 `AppModel` 的近似模拟，也不需要为可执行目标搭测试 target（SwiftPM 对测试可执行目标有已知限制，避开它更稳）。

需要新增的测试：

| 测试 | 断言 |
|---|---|
| 重复保存 | 第二次调用被拒绝，`store.save` 只被调用一次 |
| 保存期间启动服务 | 启动被拒绝，控制器状态未被改变 |
| 保存期间备份/恢复 | 被拒绝并给出明确提示 |
| A 类变更成功 | 停服 → 控制器置空 → 新设置持久化 |
| B 类变更成功 | 停服 → 用**新设置**重新生成 → 重启；控制器非 nil |
| B 类重新生成失败 | 磁盘配置恢复为旧值，运行状态恢复为原状态，`settings` 未被修改 |
| B 类重启失败 | 同上，且 `webServicesRunning` 反映真实状态而非乐观值 |
| 非法设置 | 校验失败时**服务未被停止**，`store.save` 未被调用 |
| 控制器不丢 | 整个流程中 `webController` 从未变为 nil |

---

## 阶段二：Web 配置兼容性

### 2.1 背景

生成的 Apache 配置只加载 11 个模块，且所有 `<Directory>` 都是 `AllowOverride None`，`.htaccess` 完全不生效。实测所需模块在 `runtime/stage/apache/lib/httpd/modules/` 和 `/opt/homebrew/opt/httpd/lib/httpd/modules/` 下都齐全（rewrite、headers、expires、deflate、filter、autoindex、authn_file、authz_user、authz_groupfile、auth_basic、access_compat）。

影响：WordPress 固定链接、Laravel、ThinkPHP 等依赖伪静态的项目会 404 或 403。

### 2.2 `Options` 必须显式关闭 `FollowSymLinks`

**v2 错误**：写成 `Options -Indexes +SymLinksIfOwnerMatch`，并称这「比原始代码更严」。两处都不对。

随包 Apache 2.4.68 官方手册（`manual/mod/core.html.en`，Options 指令）原文：

> **FollowSymLinks** The server will follow symbolic links in this directory. **This is the default setting.** … Disabling this option also prevents mod_rewrite from operating in per-directory context (`.htaccess` files and `<Directory>` sections).

> **SymLinksIfOwnerMatch** The server will only follow symbolic links for which the target file or directory is owned by the same user id as the link.

> Normally, if multiple Options could apply to a directory, then the most specific one is used and others are ignored; the options are not merged. **However if all the options on the Options directive are preceded by a `+` or `-` symbol, the options are merged.** Any options preceded by a `+` are added to the options currently in force, and any options preceded by a `-` are removed from the options currently in force.

两点结论：

1. **`FollowSymLinks` 是默认值。** 由于 `+`/`-` 语法是「合并到当前生效的选项集」，只写 `+SymLinksIfOwnerMatch` 会把该项加入，而继承来的默认 `FollowSymLinks` **仍然生效**，实际效果是两者同时开启，比预期宽松得多。
2. **`SymLinksIfOwnerMatch` 比 `-FollowSymLinks` 更宽松，不是更严。** 前者允许同属主符号链接，后者一个都不允许。v2 的说法反了。

正确写法（显式先移除再添加）：

```apache
Options -Indexes -FollowSymLinks +SymLinksIfOwnerMatch
```

另外，官方手册对这两个选项都注明了：

> This option should not be considered a security restriction, since symlink testing is subject to race conditions that make it circumventable.

所以不应把它当作一项加固成果来宣传，只是满足 mod_rewrite 的启用前提。

关于 mod_rewrite 的启用前提，官方手册（`manual/mod/mod_rewrite.html`，Per-directory Rewrites）原文：

> To enable the rewrite engine in this context, you need to set `RewriteEngine On` **and** at least one of the `FollowSymLinks` or `SymLinksIfOwnerMatch` `Options` must be enabled. Note that these options cannot be set in a distributed configuration file (`.htaccess`) unless `AllowOverride` permits it in the server configuration.

最后一句正好支持「不放开 `Options` 覆盖类」的设计——我们在服务器配置里设好，不让 `.htaccess` 改。

### 2.3 默认站点 `www` 与登记网站同等对待

`www` 就是 MacStack 对应 XAMPP `htdocs` 的目录，排除它等于默认网站仍不兼容。

| 目录 | Options | AllowOverride |
|---|---|---|
| `runtime/www`（默认站点，≈ htdocs） | `-Indexes -FollowSymLinks +SymLinksIfOwnerMatch` | 与登记网站相同 |
| 用户登记的网站目录 | 同上 | 同上 |
| `runtime/health`（内部健康检查） | `-Indexes -FollowSymLinks` | `None` |
| phpMyAdmin 目录 | `-Indexes -FollowSymLinks` | `None` |

已确认 `health` 与 `www` 是**同级**目录（都在 runtime 根下，`WebStack.swift` 第 196–197 行），给 `www` 放开覆盖类不会波及健康检查端点。

### 2.4 `Indexes` 覆盖类与 `mod_autoindex` 解耦

**v2 错误**：断言 `Indexes` 覆盖类与 `mod_autoindex` 必须绑定。这是错的。

官方手册原文：

> **DirectoryIndex** … Override: **Indexes** … Status: Base **Module: mod_dir**

> **IndexOptions** … Override: **Indexes** … Status: Base **Module: mod_autoindex**

`DirectoryIndex` 属于 `mod_dir`（已加载的 `dir_module`），**不需要** `mod_autoindex`。只有 `IndexOptions`、`AddIcon*`、`HeaderName`、`ReadmeName` 这些才需要。

所以正确策略是：

- **授予 `Indexes` 覆盖类** —— 让 `.htaccess` 能设 `DirectoryIndex`（很常见）
- **不加载 `mod_autoindex`** —— 目录列表本来就被 `Options -Indexes` 禁止，模块没有存在的必要
- 把 `IndexOptions` / `AddIcon*` / `HeaderName` / `ReadmeName` 加入「需要可选模块」的预检清单（见 2.6 B 类）

### 2.5 覆盖类与模块的依赖关系（保留 v2 的核心结论）

v2 提出的「授予覆盖类却不加载模块会导致 500」这个方向是对的，只是 `Indexes` 那一行归错了模块。修正后的对照表：

| 覆盖类 | 典型指令 | 所需模块 | 默认加载 |
|---|---|---|---|
| `FileInfo` | `RewriteRule` / `RewriteBase` | mod_rewrite | 是 |
| `FileInfo` | `Header` / `RequestHeader` | mod_headers | 是 |
| `FileInfo` | `SetEnvIf` | mod_setenvif | 是 |
| `FileInfo` | `ErrorDocument` / `ForceType` | core | — |
| `Indexes` | `DirectoryIndex` | **mod_dir** | 是（已加载） |
| `Indexes` | `IndexOptions` / `AddIcon*` | mod_autoindex | **否**，按需 |
| `AuthConfig` | `AuthUserFile` | **mod_authn_file** | 是 |
| `AuthConfig` | `AuthBasicProvider` | **mod_auth_basic** | 是 |
| `AuthConfig` | `Require user` / `Require group` | **mod_authz_user** / **mod_authz_groupfile** | 是 |
| `Limit` | `Order` / `Allow` / `Deny`（2.2 兼容） | **mod_access_compat** | 是 |

建议在代码里把覆盖类与必需模块绑成一组常量，缺任何一个就 `prepare` 报错，防止漂移：

```swift
struct HtaccessCompatibility {
    static let allowOverride = "FileInfo Indexes AuthConfig Limit"
    static let requiredModules = [
        "rewrite",          // FileInfo: RewriteRule
        "headers",          // FileInfo: Header
        "setenvif",         // FileInfo: SetEnvIf
        "authn_file",       // AuthConfig: AuthUserFile
        "auth_basic",       // AuthConfig: AuthBasicProvider
        "authz_user",       // AuthConfig: Require user
        "authz_groupfile",  // AuthConfig: Require group
        "access_compat",    // Limit: Order/Allow/Deny
    ]
    // 按需加载，不在此列表：autoindex（IndexOptions）、expires、deflate + filter
}
```

`status` 模块确认不加载——它不提供任何 `.htaccess` 覆盖类，WordPress/Laravel 也不需要，只会增加攻击面。

### 2.6 `.htaccess` 预检：必须求值 `IfModule` 条件

**v2 错误**：只要正则匹配到 `php_value` 就阻止网站启用。这个概括过头了。

`<IfModule mod_php.c>…</IfModule>` 这类条件块在模块未加载时会被**整体跳过**。所以被 `<IfModule mod_php*>` 包裹的 `php_value` 不会导致 500，只是静默不生效。反过来，被 `<IfModule rewrite_module>`（已加载）包裹的 `php_value` 会被处理，就会 500。

正确做法：预检要跟踪 `<IfModule>` 嵌套并**对条件求值**，只标记那些**实际会被处理**的指令。

预检结果分三类：

**A 类 —— 阻止启用**

顶层（不在任何会被跳过的 `IfModule` 内）出现 `php_value` / `php_flag` / `php_admin_value` / `php_admin_flag`。PHP 走 PHP-FPM，没有 mod_php，这些指令必然 500。

- 阻止该网站启用，界面明确提示，**不提供「忽略」选项**
- 提供辅助功能：把可迁移项转写到 `.user.ini`

**A 类之二 —— 需要未授予的覆盖类（实施时补上，v3 遗漏）**

顶层出现 `Options` 或 `XBitHack`。MacStack 默认的 `AllowOverride FileInfo Indexes AuthConfig Limit` **刻意不含 `Options`**（见 2.3，否则站点能用 `.htaccess` 推翻 `-FollowSymLinks`），代价是这些指令会让 Apache 报 `not allowed here` 并返回 **HTTP 500**。

v3 的预检只查 `php_value` 和模块依赖，**完全漏掉这一类**。这是实施后跑端到端测试才发现的：`htaccess-smoke-test` 里加一个裸 `Options -MultiViews -Indexes` 的 fixture，实测返回 500 而预检「无发现」。

处理方式与 A 类相同（阻塞级），提示里给出可执行出路——在设置页开启「允许 .htaccess 覆盖 Options」，开启后放行。

**注意必须求值 `IfModule` 后再判断**：Laravel / Symfony 官方 `.htaccess` 里的 `Options -MultiViews -Indexes` 被包在 `<IfModule mod_negotiation.c>` 中，而该模块未加载 → Apache 整块跳过 → 不会报错。如果一刀切地见到 `Options` 就拦，会把标准框架项目误判成不能启用。这两种情况都已加进 `htaccess-smoke-test` 与单元测试。

| `.htaccess` 指令 | 级别 | 可转 `.user.ini` |
|---|---|---|
| `php_value upload_max_filesize` | PERDIR | 可以 |
| `php_value post_max_size` | PERDIR | 可以 |
| `php_value memory_limit` | PERDIR | 可以 |
| `php_value max_execution_time` | PERDIR | 可以 |
| `php_flag display_errors` | PERDIR | 可以 |
| `php_admin_value` / `php_admin_flag` | — | **不可以**，只能改 MacStack 私有 `php.ini` |

生成 `.user.ini` 是写文件操作，必须用户确认后执行。

**B 类 —— 提示但不阻止**

命中以下指令且对应模块未加载时，提示用户去设置页开启，并说明否则会 500：

| 指令 | 所需模块 |
|---|---|
| `ExpiresActive` / `ExpiresDefault` / `ExpiresByType` | expires |
| `AddOutputFilterByType` / `SetOutputFilter` / `Deflate*` | deflate + filter |
| `IndexOptions` / `AddIcon*` / `HeaderName` / `ReadmeName` | autoindex |

**C 类 —— 记录但不阻止**

被 `<IfModule mod_php*>` 包裹的 `php_value`：Apache 会跳过，站点能跑，但这些设置**静默失效**。记录到站点日志并提示用户，因为用户往往以为它们生效了。

### 2.7 预检之外还要真实 HTTP 验证

静态分析可能漏判（比如条件嵌套写得很绕、或者指令通过 `Include` 引入）。所以启用网站后必须补一次真实请求：

- 现有 `refreshWebsiteStatuses()`（第 1222 行）已经会请求每个启用站点并把 `(200..<500)` 视为「运行中」
- 扩展它：显式识别 **HTTP 500**，在界面标注「站点返回 500，可能是 `.htaccess` 中的指令不被支持」并给出日志入口
- 把「启用网站 → 实际请求 → 不是 500」作为阶段二的验收条件之一

这条同时也修正了 v2「只靠正则阻止」的过度概括——静态预检负责提前拦截，HTTP 验证负责兜底。

### 2.8 php.ini 实用默认值

**文件**：`WebStack.swift` 第 485–494 行。当前只有 10 行，默认值（`upload_max_filesize` 2M、`post_max_size` 8M）跑真实项目很容易撞墙。

multipart 请求体除文件本身外还有 boundary、各字段头等开销，`post_max_size` 必须**大于** `upload_max_filesize`：

```
memory_limit = 512M
upload_max_filesize = 64M
post_max_size = 80M
max_execution_time = 120
max_input_time = 120
max_input_vars = 5000
```

约束关系，生成时断言，不满足就明确报错：

```
post_max_size > upload_max_filesize
memory_limit  >= post_max_size
```

三项做成可配置（`uploadMaxFilesizeMB`、`postMaxSizeMB`、`memoryLimitMB`），在设置页暴露。

### 2.9 时区不要硬编码 UTC

第 491 行 `date.timezone = UTC` 会让所有 PHP 日期函数返回 UTC。新增 `Preferences.phpTimezone: String = ""`，空值表示跟随系统：

```swift
let zone = preferences.phpTimezone.isEmpty
    ? (TimeZone.current.identifier.isEmpty ? "UTC" : TimeZone.current.identifier)
    : preferences.phpTimezone
```

生成前校验 `TimeZone(identifier:) != nil`，非法值回退系统时区并提示。

### 2.10 `TypesConfig` 改用运行时自带文件

第 428 行硬编码 `TypesConfig /etc/apache2/mime.types`，指向系统文件，与「核心运行时不依赖系统组件」的定位矛盾。

实测：Homebrew 的 httpd keg 里没有 `mime.types`（实际在 `/opt/homebrew/etc/httpd/mime.types`），bottle 副本被 `ditto` 带进了 `runtime/stage/apache/.bottle/etc/httpd/mime.types`。

1. `build-portable-runtime.sh`：把 `.bottle/etc/httpd/mime.types` 显式搬到稳定路径 `apache/etc/httpd/mime.types`
2. `WebStack.swift`：优先用 `serverRoot/etc/httpd/mime.types`，不存在时回退 `/etc/apache2/mime.types`，都没有则明确报错

### 2.11 顺手修一处不一致

第 278 行 phpMyAdmin 的 `<Directory>` 用了 `Options FollowSymLinks`，与修订后其他目录不一致，且 phpMyAdmin 静态资源不需要跟随符号链接。统一改为 `Options -Indexes -FollowSymLinks` + `AllowOverride None`。

### 2.12 验收

1. `bash scripts/test.sh` 33 项保持通过；现有断言在 `CoreTests.swift` 第 311、455、461 行，需为新增 `LoadModule` 和 `AllowOverride` 补断言
2. 新增单元测试：
   - `allowHtaccess = false` → `AllowOverride None`；`true` → `FileInfo Indexes AuthConfig Limit`
   - `requiredModules` 中任一模块缺失 → `prepare` 抛错
   - 默认站点 `www` 与登记网站生成**相同**的 Options/AllowOverride
   - 生成的 Options 字符串**同时包含** `-FollowSymLinks` 和 `+SymLinksIfOwnerMatch`（防止 2.2 的继承问题回归）
   - 预检对 `<IfModule mod_php.c>` 包裹的 `php_value` 判为 C 类而非 A 类
3. 端到端：`sites-smoke-test` 的 fixture 放一个带 `RewriteRule` 的 `.htaccess`，断言伪静态路径返回 200 —— **2.2 的直接回归测试**
4. 端到端：站点返回 500 时界面标注且不误报为「运行中」
5. 安全回归：`.env`、`.git/config` 仍返回 403

### 2.13 残留风险

- 放开 `FileInfo` 后，`.htaccess` 可以改 `ErrorDocument` 指向本地文件。服务只监听 `127.0.0.1`，风险可接受，应在 README 写明
- `SymLinksIfOwnerMatch` 在符号链接属主与目标属主不一致时会拒绝服务，个别项目可能因此 403。官方手册本身也指出该检查存在竞态、不应视为安全边界，所以这是有意的兼容性取舍，出错原因应能在站点错误日志里查到

---

## 阶段三：许可证合规

### 3.1 根因更正（v2 判断错误）

**v2 错误**：断言「这条收集思路不可能成功，不是路径写错了」。实际是**路径写错了**，而且我上次的验证方法复刻了同一个错误，所以得出了错误结论。

事实：`runtime/stage/apache/LICENSE`（25479 字节）和 `NOTICE`（721 字节）**都存在**。

真正的根因是 `brew --prefix` 返回的是 `opt` 符号链接，而 `find` 默认不下降到作为起点的符号链接：

```
$ P=$(brew --prefix httpd)        # /opt/homebrew/opt/httpd   ← 符号链接
$ R=$(readlink -f "$P")           # /opt/homebrew/Cellar/httpd/2.4.68
$ find "$P" -maxdepth 2 -type f -iname 'license*' | wc -l   → 0
$ find "$R" -maxdepth 2 -type f -iname 'license*' | wc -l   → 2
```

所以 `build-portable-runtime.sh` 第 54 行拿到的 `formula_prefix` 是符号链接，`find` 在起点就停住了，循环只创建了空目录。

**修复**：在 `find` 之前解析真实路径。

```bash
formula_prefix="$($BREW --prefix "$formula" 2>/dev/null || true)"
[ -d "$formula_prefix" ] || continue
formula_prefix="$(/bin/realpath "$formula_prefix")"   # ← 新增：解析符号链接
```

这个修正让**已有的上游 LICENSE/NOTICE 文件能够被正常收集**，不需要另外去上游仓库抓。SPDX 数据只在「公式目录里确实没有许可证文件」时作为补充来源。

### 3.2 空目录仍需修复

```
$ find runtime/stage/licenses -mindepth 1 -maxdepth 1 -type d | wc -l
59
$ find runtime/stage/licenses -type f | wc -l
0
```

59 个组件目录、0 个文件。修复 3.1 的路径问题后重新构建即可填充。

### 3.3 版本锁定与数据来源

**v2 已修正**：不从 SPDX 的 `main` 分支下载。实测最新 tag 为 `v3.28.0`（2026-02-20 发布，无预打包 assets，只有 tarball），固定 tag 下 `licenses.json`（含 `licenseListVersion: 3.28.0`，727 条）与 `details/<ID>.json`（含 `licenseText`、`isOsiApproved`、`isFsfLibre`、`isDeprecatedLicenseId`）均可访问。

建议流程：

1. **优先使用组件自带的许可证文件**（3.1 修复后即可获得），SPDX 数据作为补充
2. SPDX 正文 vendor 进仓库 `vendor/spdx/v3.28.0/<ID>.txt`，配 `MANIFEST.sha256` 记录每个文件的 SHA-256；tag 是常量，写死在刷新脚本里
3. `build-portable-runtime.sh` **只从组件目录和 vendor 目录读取，完全不联网**
4. 非标准标识符（SPDX 查不到的）**让构建失败并列出清单**，不静默跳过
5. `license` 字段按 `AND` / `OR` / `WITH` 拆成原子标识符逐个处理（`php@8.2` 的值是一长串 `PHP-3.01 AND Zend-2.0 AND … AND LGPL-2.1-only AND LGPL-2.1-or-later AND …`）

Apache-2.0 第 4(d) 条要求随附 NOTICE —— 3.1 修复后 `apache/NOTICE` 能被正常收集，无需额外抓取。

其他可用来源（实测）：`brew info --json=v2` 提供 SPDX 标识符（httpd=`Apache-2.0`、mariadb@11.4=`GPL-2.0-only`）；`<组件>/sbom.spdx.json` 是 Homebrew 生成的 SPDX 2.3 SBOM，含 `licenseConcluded`，是**有价值的合规产物，不应删除**，应归集到 `licenses/sbom/`。

### 3.4 清理打包残留

删除各组件下的 `INSTALL_RECEIPT.json`（含构建机安装信息）和 `.brew/`（含公式源码，许可证提取完成后再删）。`.bottle/` 按 2.10 先搬 `mime.types` 再删。`sbom.spdx.json` 保留并归集。

### 3.5 验收必须逐组件检查（v2 遗漏）

**v2 遗漏**：验收写成 `find licenses -type f | wc -l` 显著大于 0。这个判据太弱——只要有一个组件有文件就会通过，其余 58 个空目录照样漏过。

改为：

- **逐组件检查**：闭包内每个公式的 `licenses/<formula>/` 都必须至少有一个文件，否则列出清单并让构建失败
- 若某组件确实上游未提供许可证文件，允许在显式白名单里登记（附 SPDX 标识符与来源说明），而不是静默留空
- `verify-portable-runtime.sh` 增加该校验，防止再次静默退化
- 在完全断网的构建机上跑 `build-portable-runtime.sh` 能成功（验证 3.3 的「发行构建不联网」）

### 3.6 需要正式合规审核的点

不使用「独立进程 / 聚合」之类的说法直接下结论。MariaDB 的 Licensing FAQ 指出，判断「应用是否必须依赖服务器才能工作」还有进一步条件，「独立进程」本身不构成免于 GPL 义务的充分条件。

本方案只做两件事：如实收集并随包提供许可证声明与正文；在 README 里准确描述现状（把「已附带许可证文件」的不准确表述改掉）。

待审清单：MariaDB `GPL-2.0-only` 的分发形态；PHP 许可证表达式中的 `LGPL-2.1-only` / `LGPL-2.1-or-later` 在动态链接下的义务；`libreadline`（GPL）与 `libedit`（BSD）实际链接了哪个；60 个扁平化 dylib 各自的上游许可证。

---

## 阶段四：健壮性小修

### 4.1 `CommandOutput.standardError` 恒为空

`WebStack.swift` 第 40–63 行把 stdout 和 stderr 合进同一个 pipe，第 62 行返回 `standardError: ""`。字段永远是空字符串，调用方的 `result.standardOutput + result.standardError` 是无效拼接。

建议改名而非拆分：改成 `combinedOutput`，删掉 `standardError`。拆分两个 pipe 需要并发读取才能避免死锁，对这个项目没有实际收益。

### 4.2 自动备份的计数用错数据源

`AppModel.swift` 第 651 行用 `databases.count`——这是 `@Published` 的界面缓存，而 `detached` 任务内部已有新列出的结果。改用任务返回的计数。

### 4.3 自动备份按库判断间隔

`BackupCatalog.swift` 第 57–59 行 `lastAutomaticBackupDate()` 返回**全局**最新时间，导致新加的业务库要等满整个间隔（最长 168 小时）才被首次备份。改为 `lastAutomaticBackupDate(database:)`，循环内逐库判断。

### 4.4 备份文件没有保留策略

`BackupCatalogStore.register` 第 44 行只把 catalog 截断到 200 条记录，**`.sql` 文件本身从不删除**。新增 `backupRetentionDays`（默认 30）或 `maxAutomaticBackups`（默认 50），清理超期/超量的**自动**备份（`automatic == true`），手工备份不动，同时移除对应 catalog 记录。

### 4.5 日志轮转：明确定义时机，而不是永久排除

**v2 错误**：提议在 `LogMaintainer` 里永久跳过 `*-launcher.log`。这会让这些日志**彻底失去轮转**，长期运行后无限增长——只是把一个 bug 换成了另一个。

真正的问题是 `LogMaintenance.swift` 第 45 行 `moveItem` 改名后第 46 行新建空文件，而 `LocalWebStackController.start` 第 48–50 行持有的 `FileHandle` 会继续写入被改名的 `.1` 文件。

正确做法是**把轮转时机和文件句柄的生命周期对齐**：

- `LocalWebStackController.start` 在打开句柄**之前**轮转自己的 `<component>-launcher.log`（此刻上一个句柄已关闭，是安全时点）
- `LocalDatabaseController` 对 MariaDB 的 launcher 日志同样处理
- `WebStackPreparer.prepare`（第 532 行）在停服状态下轮转全目录，此时包含 launcher 日志也安全
- `LogMaintainer.rotate` 保持通用，在文档注释里写明「调用前必须确认目标日志没有打开的写入句柄」，并**不**硬编码排除任何文件名

这样 launcher 日志有确定的轮转时点，其他日志由停服时的整理覆盖。

### 4.6 残留进程恢复不应中断整个流程

`ResidualServiceRecovery.swift` 第 45–47 行遇到第一个无法确认身份的进程就 `throw`，导致后面的候选（PHP-FPM、MariaDB）**根本不会被检查**。改为逐个处理、把失败收集到结果里：

```swift
public struct ResidualServiceRecoveryResult {
    public let stoppedProcessCount: Int
    public let removedStalePIDCount: Int
    public let unresolved: [(pid: Int32, command: String)]   // 新增
}
```

`AppModel.launch()` 改为汇总展示。

### 4.7 进程身份复核（v2 方案无效）

**v2 错误**：提议「在命令行核对与发信号之间再做一次 `kill(pid, 0)` 确认」。`kill(pid, 0)` 只能证明**某个**进程占用了这个 PID，无法证明它还是原来那个——PID 被回收后重新分配，这个调用照样返回成功。等于没做复核。

同一文件当前的时序是：第 39 行 `kill(pid, 0)` 判存活 → 第 44 行读命令行核对身份 → 第 48 行发 `SIGTERM`。要缩小窗口，必须**复核的是身份而不是存在性**：

1. 在第一次读命令行时，**同时记录进程启动时间**（`ps -p <pid> -o lstart=` 或 `ps -o lstart=`）
2. 发信号前**立即重新读取命令行与启动时间**，两者都与第一次记录的一致才发信号
3. 任一不一致 → 视为身份已变，跳过该 PID 并按「无法确认」处理（进 4.6 的 `unresolved`）

启动时间在同一 PID 复用后会不同，所以「命令行 + 启动时间」双重比对是 macOS 上可行且有效的身份判据。

另外 `kill(pid, 0)` 在进程存在但无权限时返回 `-1`（`errno == EPERM`），当前代码会当成「进程已死」进而删掉 PID 文件。应区分 `ESRCH` 与 `EPERM`：只有 `ESRCH` 才代表进程确实不存在。

完全消除竞态需要 `pidfd`（macOS 没有），把窗口缩到最小并在注释里说明残留风险即可。

### 4.8 验收

`bash scripts/test.sh` 全绿，新增测试覆盖：按库间隔查询、`LogMaintainer` 在无打开句柄时正常轮转 launcher 日志、`ResidualServiceRecovery` 在部分进程无法识别时仍继续处理后续候选、启动时间不一致时拒绝发信号。

---

## 阶段五：工程结构与本地化

放在最后。收益长期，但改动面大。

> **范围声明：本阶段不含「自动更新」。**
> 本文档前面提到过「自动更新」，但正文**没有给出任何实施步骤或验收标准**。因此**不能把自动更新算作本方案已覆盖或已完成的工作**。它涉及发布地址、签名更新清单、下载校验、安装与回滚，是一套独立课题，建议单独立项（可参考 `docs/NEXT_STEPS.md` 第 3、4 条）。本方案完成后，README 的完成度描述里不应包含自动更新。

### 5.1 拆分过大的文件

- `AppModel.swift` 1506 行、约 70 个方法，涵盖服务控制、数据库、备份、扩展、迁移、网站、设置七块职责。按职责拆成多个 `@MainActor` 扩展文件
- `ContentView.swift` 993 行，单个 `struct ContentView` 用 8 个计算属性承载 8 个页面，另有 3 个 sheet。每页拆成独立 `View` 文件，放进 `Sources/MacStackApp/Pages/`

**实施结果**（2026-09-14）：

```
AppModel.swift              188  核心：状态、init、launch、inspect
AppModel+Services.swift     414  开发者工具、PHP 扩展、依赖、Web/数据库启停
AppModel+Settings.swift     258  网站设置应用、状态刷新、监控与调度、重配置一致性
AppModel+Backups.swift      186  数据库列表、导出、恢复、自动备份与保留
AppModel+Websites.swift     175  保存预设、网站增删改、证书、Finder 入口
AppModel+Database.swift     169  phpMyAdmin、密码、建库、PDO 模板
AppModel+Migration.swift    160  XAMPP 盘点、网站与旧库迁移
ContentView.swift            71  仅导航骨架
Pages/*.swift             9 个文件  八个页面 + 共用的 PageHeading
Sheets/*.swift            3 个文件  编辑网站、创建项目、迁移旧数据库
```

**必须记录的代价**：Swift 的 `private` 是**文件级**作用域，把一个类型拆到多个文件意味着被多文件共用的成员只能是 internal。本次放宽了 8 个存储属性（`webController`、`databaseController`、`backupCatalog` 等）、`operationGate`，以及 12 个方法。这**降低了封装**——模块内任意类型技术上都能读到 `webController`。已在 `AppModel.swift` 类头写明原因，并要求新增成员优先保持 `private`。

**判断**：这次拆分只改善了可读性，并没有减少耦合（约 70 个方法几乎都读写同一组状态）。真正减少耦合需要把内聚的子职责抽成独立对象（如备份调度器、服务巡检器各自持有自己的 Task 与状态），那是另一件事，本方案不含。

### 5.2 版本号单一来源

`ContentView.swift` 第 43 行硬编码 `Text("0.10.0 · 便携运行时\n原生 Apple Silicon")`，与 `Resources/Info.plist` 的 `CFBundleShortVersionString` 重复。改为从 `Bundle.main.object(forInfoDictionaryKey:)` 读取。

### 5.3 本地化

目前没有任何 `.strings` / `.xcstrings` 文件，全部界面文案以中文字面量硬编码。

**实施时按实际工作量重新评估，结论与 v3 的设想不同，做法已调整。** 实测统计：

| 类别 | 数量 | 是否已可本地化 |
|---|---|---|
| `Text("字面量")` | 49 | **是**——SwiftUI 的字符串字面量自动绑定 `LocalizedStringKey` |
| `Button` / `Label` / `Toggle` / `Picker` / `TextField` 字面量 | 96 | **是**，同上 |
| 赋给 `String` 属性或变量的文案（`AppModel` 里的状态与提示） | 124 | **否**——`Text(某个String变量)` 走的是 verbatim 初始化器 |

因此 v3 里「先抽出 String Catalog 并把文案迁过去」是不必要的：

- 那 145 处字面量**一行代码都不用改**，以后加 Catalog 时会自动成为本地化键。
- 真正要改的只有 `AppModel` 里那 124 处 `String`，需包成 `String(localized:)` 才会参与本地化。
- 现在手工写一个空 `.xcstrings`（没有 Xcode 界面无法验证格式）没有收益；Catalog 应该在真有第二种语言要翻译时再建。

**结论：本地化暂不做。** 等确实要出英文版时，第一步是把那 124 处 `String` 改成 `String(localized:)`（无 Catalog 时返回原字符串，行为不变），再用 Xcode 生成 Catalog 并翻译。这件事没有前置依赖，随时可插入。

本节保留这个结论，是为了避免以后有人再按「先建 Catalog」的思路白做一遍。

### 5.4 补充自动化验收

- 现在没有任何 `#Preview`
- 测试只有 `MacStackCoreTests`（33 项，覆盖 Core 层），`MacStackApp` 和 `MacStackCLI` 零覆盖
- `AppModel` 状态机的单元测试已在阶段一落地（见 1.5.1），这里剩下的是**界面层**的覆盖：SwiftUI 预览、以及把 README 里那批「手动界面验收待办」逐步转成可自动化的检查

---

## 需要你决策的点

1. **`allowHtaccess` 默认值**：建议 `true`。注意 2.2 的 `SymLinksIfOwnerMatch` 是启用重写的前提，即使 `allowHtaccess = false` 也应保留该 Options，否则与将来开启重写冲突
2. **是否加载 `mod_autoindex`**：本方案建议不加载（2.4）。若你的项目里确实有 `.htaccess` 用 `IndexOptions`，改为按需开启并在预检里提示
3. **MariaDB GPL 合规结论**：需法务判断（3.6）
4. **许可证正文来源优先级**：本方案改为「组件自带优先、SPDX 补充」（3.1 + 3.3），比 v2 的「全部从 SPDX 下载」更简单
5. **阶段五是否做**
6. **父仓库 `Documents/Playground` 怎么处理**：不在本方案范围（0.3）

---

## 建议执行顺序

1. **阶段零** —— 补齐 `.gitignore`、检查暂存清单、确立 MacStack 独立仓库、提交基线
2. **阶段一** —— 修复服务控制权安全（含并发锁与两类变更）
3. **阶段二** —— 修复 `.htaccess` / Rewrite / 默认 `www` / MIME 配置
4. **阶段三** —— 许可证合规（根因是 `find` 未解析符号链接）
5. **阶段四** —— 备份保留、计数、残留进程恢复等 6 项
6. **阶段五** —— 拆分 `AppModel`、本地化、自动更新

每个阶段完成后跑一次完整测试，并按现有格式在 README 的「本机验证记录」里追加实际验证结果。

---

## 附录 A：修订对照

### v1 → v2

| # | v1 内容 | v2 修订 |
|---|---|---|
| 1 | `-FollowSymLinks` + 启用 RewriteRule | 改为需开启符号链接选项（方向正确，取值在 v3 修正） |
| 2 | 只给登记网站放开，排除 `www` | `www` 与登记网站同等对待 |
| 3 | `php_value` 表述为「已忽略」 | 改为阻止启用 + `.user.ini` 转换 |
| 4 | 默认加载 `autoindex` 和 `status` | `status` 不加载；`autoindex` 与 `Indexes` 绑定（v3 修正为解耦） |
| 5 | `post_max_size` 与 `upload_max_filesize` 同为 64M | 改为 64M / 80M 并断言 `post > upload` |
| 6 | 从 SPDX `main` 下载 | 锁定版本 + vendor + SHA-256 |
| 7 | 称「不是 git 仓库」 | 更正为父仓库零提交、`MacStack/` 未跟踪 |
| 8 | 许可证空目录「61 个」 | 更正为 59 个 |
| 9 | 先做 Web 配置 | 安全缺陷提前 |

### v2 → v3

| # | v2 内容 | 问题 | v3 修订 | 依据 |
|---|---|---|---|---|
| 1 | `save` 改 `async`，未处理重入 | 每个 `await` 都是挂起点，可重入 | 新增覆盖全程的 `savingSettings` 锁并纳入 `hasCriticalOperation`；**先校验后停服**；新增时区/上传/`.htaccess` 开关纳入判断 | 用户复核 |
| 2 | `Options -Indexes +SymLinksIfOwnerMatch` | 默认值就是 `FollowSymLinks`，`+` 语法是合并，继承的默认项仍生效；且称其「更严」方向错误 | 改为 `-Indexes -FollowSymLinks +SymLinksIfOwnerMatch`；不再声称是加固 | 随包官方手册 `core.html.en` Options 指令原文 |
| 3 | `Indexes` 与 `mod_autoindex` 必须绑定 | `DirectoryIndex` 属 `mod_dir`，不需 `mod_autoindex` | 解耦：授予 `Indexes` 但不加载 `autoindex`；`IndexOptions` 等入预检 B 类 | 官方手册 `mod_dir.html.en` / `mod_autoindex.html.en` 原文 |
| 4 | 正则匹配 `php_value` 即阻止启用 | `<IfModule mod_php.c>` 内的会被跳过，不必然报错 | 预检求值 `IfModule` 条件，分 A/B/C 三类；补真实 HTTP 500 验证 | 用户复核 |
| 5 | 「收集思路不可能成功，不是路径写错了」 | 结论错误，且验证方法复刻了同一错误 | 根因是 `find` 不下降到符号链接起点，需先 `realpath`；`apache/LICENSE`、`NOTICE` 确实存在；验收改逐组件检查 | 实测 symlink 与 realpath 的 `find` 结果差异 |
| 6 | `.gitignore` 已正确忽略构建产物 | 漏了 `out/`（76 MB）等 | 补齐忽略规则；提交前跑 `git add -A --dry-run` 检查暂存清单（当前 1570 条） | `du -sh` 实测 |
| 7 | 永久跳过 `*-launcher.log` | 这些日志会彻底失去轮转 | 改为把轮转时机与文件句柄生命周期对齐（start 前 / 停服时） | 用户复核 |
| 8 | 复核时再调一次 `kill(pid, 0)` | 只能证明 PID 被占用，不能证明是原进程 | 改为「命令行 + 进程启动时间」双重比对 | 用户复核 |
| 9 | 许可证正文全部从 SPDX 下载 | 组件自带文件已存在，无需外抓 | 改为组件自带优先、SPDX 补充 | 同 #5 |
