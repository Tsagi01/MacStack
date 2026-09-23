# 参与 MacStack

## 环境要求

- macOS 14 或更新版本（Apple Silicon）
- **完整 Xcode 15 或更新版本**（`#Preview` 等 SwiftUI 宏需要）
- [Homebrew](https://brew.sh/)（**仅开发和构建时需要**；最终应用不依赖它）

### 必须是完整 Xcode，不能只有 Command Line Tools

本项目用 SwiftUI 的 `#Preview` 宏，它的宏插件**只在完整 Xcode 里**。只装了 Command Line
Tools 时，构建会报：

```
error: external macro implementation type 'PreviewsMacros.SwiftUIView' could not be found
for macro 'Preview(_:body:)'; plugin for module 'PreviewsMacros' not found
```

**这个错误信息很难联想到工具链**，所以先确认一下：

```sh
xcode-select -p          # 指向 /Library/Developer/CommandLineTools 就是只有 CLT
```

`scripts/swift-env.sh` 会在检测到 CLT 时自动切到已安装的完整 Xcode（只影响当前进程，
不改动系统的 `xcode-select`），所以**下面的构建步骤都从 `source` 它开始**。
如果机器上根本没装 Xcode，它无能为力，需要先装。

## 构建与运行

```sh
git clone https://github.com/Tsagi01/MacStack.git
cd MacStack
source scripts/swift-env.sh
swift run MacStack
```

`scripts/swift-env.sh` 做两件事：选择已安装的 Xcode（不改动系统的 `xcode-select`），
以及把编译缓存放到 `~/Library/Caches/MacStack/SwiftBuild`。

**第二条很重要**：编译缓存必须放在非同步目录。放在 `Documents/` 下时，文件提供器会给
测试包附加 FinderInfo 扩展属性，导致签名步骤失败。因此脚本里的 `BUILD_CACHE`
**必须 `export`**——调用方经常再用 `bash -c` 启动子进程，不导出的话子进程读到空值，
SwiftPM 会退回 `$PWD/out`，产物又回到 `Documents/` 下。

## 测试

```sh
source scripts/swift-env.sh
swift test
```

### 在受限环境（沙箱、CI 容器）里

```sh
swift test --disable-sandbox
```

SwiftPM 默认用 `sandbox-exec` 编译 manifest，受限环境里会报
`sandbox_apply: Operation not permitted`。**普通终端不需要这个参数。**

### 验收套件

`macstackctl` 提供十条端到端命令，它们会**真实启动服务**并绑定本机端口：

```sh
source scripts/swift-env.sh
swift run macstackctl prepare              # 生成并校验 Web 配置
swift run macstackctl smoke-test           # 启停 Apache 与 PHP-FPM
swift run macstackctl sites-smoke-test     # 双站点、端口冲突、敏感文件拦截、健康探测分类
swift run macstackctl htaccess-smoke-test  # 伪静态、.htaccess 开关、预检分类、框架兼容
swift run macstackctl prepare-database
swift run macstackctl database-smoke-test
swift run macstackctl database-backup-smoke-test   # 含中文数据的导出与两条恢复路径
swift run macstackctl prepare-phpmyadmin
swift run macstackctl full-smoke-test      # 全栈
swift run macstackctl audit-xampp          # 只读盘点旧 XAMPP
swift run macstackctl health-probe         # 真实 HTTP 探测，可复现界面状态
```

提交前请至少跑 `swift test` 与 `sites-smoke-test`、`htaccess-smoke-test`、
`database-backup-smoke-test`。

### 注意：部分验收命令会写入真实的 MacStack 目录

验收套件测的是真实组件，因此**不是全部隔离**：

| 命令 | 作用位置 |
|---|---|
| `sites-smoke-test`、`htaccess-smoke-test` | 临时目录（`/tmp/macstack-*`），完全隔离 |
| `prepare`、`smoke-test`、`prepare-phpmyadmin` | **`~/Library/Application Support/MacStack/runtime/`** |
| `prepare-database`、`database-smoke-test`、`database-backup-smoke-test` | 同上，且会**启动/停止数据库、创建并删除临时库** |
| `audit-xampp` | 只读盘点，不修改任何东西 |

也就是说：**在开发机上跑这些命令会改动你已安装的 MacStack 的配置与数据库目录**。
它们不会删除既有数据（`prepare-database` 遇到非空但未初始化的数据目录会拒绝），
但如果你在用同一台机器上的正式版 MacStack，建议先停掉它的服务。

`sites-smoke-test` / `htaccess-smoke-test` 之所以用临时目录，是因为它们要验证的是
「双站点、端口冲突、`.htaccess` 预检」这些与具体安装位置无关的行为。

## 代码约定

### 注释写「为什么」

这个项目里的注释主要解释**为什么这样写**，尤其是「这里曾经出过什么问题」。
例如：

```swift
/// 之前把 `200..<500` 一律显示成「运行中」，于是 404、403 被当成正常网站。
```

这类注释的价值在于防止回归——后来者看到它就知道不能简单改回去。
「这一行做了什么」通常不需要注释，代码本身已经说了。

### 测试要能真的抓到问题

给缺陷写回归测试时，**请验证这条测试在修复前会失败**。做法是临时把修复还原
（或复刻旧实现），确认测试报错，再改回来。

这不是形式主义：并发、竞态、解码兼容这类问题的测试，很容易因为压力不足或数据不对
而「永远通过」——那样的测试等于没写。

### 持久化结构加字段要手写解码

给 `Codable` 结构加字段时，旧数据没有这个键会让**合成解码整份失败**。
如果读取处用了 `try?`，用户看到的现象是「所有数据都消失了」。请用手写
`init(from:)` + `decodeIfPresent(...) ?? 默认值`。

### 命令行参数抽成单一来源

多个模块各自拼装同一组参数时，一致性靠人记迟早会漏。参考
`DatabaseClientArguments`（导出、导入、查询必须用同一个字符集）与
`LogOwnership`（轮转不能越过组件边界）。

## 提交改动

1. 从 `main` 开分支。
2. 一个提交做一件事，提交信息说明**为什么**改，以及验证方式。
3. 提交信息用中文，与现有历史保持一致。
4. 发起 Pull Request，说明改动动机、验证方式、以及需要人工确认的部分。

CI 会在 macOS runner 上跑构建与单元测试。验收套件不在 CI 范围——它需要绑定端口
并写入用户目录。

## 已知的、需要人来做的部分

- **签名与公证**需要项目所有者的 Apple Developer 证书。
- **许可证尚未选定**，见 [`docs/LICENSE_DECISION.md`](docs/LICENSE_DECISION.md)。
- **界面行为**（SwiftUI 交互、ATS 是否放行）只能在安装后的应用里验证，
  单元测试不能替代。
