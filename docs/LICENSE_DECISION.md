# 许可证选择：决策材料

> **这份文档是决策材料，不是法律意见。** 最终选择需要项目所有者决定，并建议经法律审核。
> 这里只把事实、由此产生的**确定义务**、以及需要判断的问题列清楚。

## 一、现状

项目**没有 `LICENSE` 文件**。在没有许可证的情况下，默认的法律状态是「保留所有权利」——
他人**没有**合法权利复制、修改或再分发这份代码。

而 README 已经邀请他人 `git clone`、并说明如何参与。这个不一致需要处理：要么选定许可证，
要么明确写出「暂未授权使用」。**保持沉默是最容易被误解的一种状态。**

## 二、随包分发的是什么

便携运行时实际分发的二进制（`runtime/stage/`）：

| 内容 | 说明 |
|---|---|
| `apache/` | httpd 及其模块 |
| `php/` | PHP 与 PHP-FPM |
| `mariadb/` | MariaDB 服务端与客户端工具 |
| `phpmyadmin/` | phpMyAdmin（PHP 源码形式） |
| `lib/` | **60 个动态库** |

**注意区分**：许可证清单里收录了 59 个组件的许可证，但其中相当一部分（`autoconf`、`m4`、
`libtool`、`gettext`、`readline`、`aspell`、`groonga` 的**可执行文件**）**并未随包分发**，
只是它们出现在 `brew deps` 闭包里。不过它们的**动态库**确实在 `lib/` 中分发
（例如 `libaspell.15.dylib`、`libgroonga.0.0.0.dylib`）。

判断义务时应当以「实际分发了哪些文件」为准，而不是以许可证清单的组件数为准。

## 三、随包分发的组件各自的许可证

按约束强度分三类（完整清单见 `licenses/THIRD-PARTY.md`）：

**宽松类**（不产生额外义务）：Apache-2.0（httpd）、BSD、MIT、ISC、Zlib、PostgreSQL、OpenSSL 等。

**LGPL 类**（弱 copyleft，随包以**动态库**形式分发）：

| 库 | 组件 | SPDX |
|---|---|---|
| `libaspell.15.dylib` | aspell | LGPL-2.1-only |
| `libgroonga.0.0.0.dylib` | groonga | LGPL-2.1-or-later |
| `libmariadb.3.dylib` | mariadb-connector-c | LGPL-2.1 |
| `libintl.8.dylib` | gettext | LGPL-2.1-or-later |
| `libltdl.7.dylib` | libtool | LGPL-2.1-or-later |
| `libgmp.10.dylib` | gmp | LGPL-3.0-or-later **或** GPL-2.0-or-later（双许可） |
| `libodbc.2.dylib` | unixodbc | LGPL-2.1-or-later **和** GPL-2.0-or-later |

**GPL 类**（强 copyleft）：

| 组件 | SPDX | 分发形式 |
|---|---|---|
| `mariadb@11.4` | **GPL-2.0-only** | 服务端与客户端二进制 |
| `phpmyadmin` | GPL-2.0-only 等 | PHP 源码 |
| `liblzo2.2.dylib` | GPL-2.0-or-later | 动态库 |

## 四、由此产生的**确定义务**（与 MacStack 自己选什么许可证无关）

1. **GPL-2.0 的源码提供义务。** 分发 MariaDB 与 phpMyAdmin 的二进制时，必须按 GPL-2.0 第 3 条
   同时提供**对应的完整源码**，或提供有效期不少于三年的**书面要约**，或给出可从同一处获取源码的指引。
   `licenses/sbom/` 里的 SPDX SBOM 与 `licenses/THIRD-PARTY.md` 目前**只满足署名与正文随包**，
   **不满足源码提供义务**。这是当前发行流程里最明确的一处缺口。

2. **LGPL 的可替换性。** 以动态库形式分发时，用户须能替换该库。当前是动态链接，
   满足这一条的前提是**不要把这些库静态链接进主程序**。`verify-portable-runtime.sh`
   已经在检查动态库引用，但可以再明确一条约束。

3. **许可证正文与署名随包。** 已由 `scripts/collect-runtime-licenses.sh` 覆盖
   （161 个文件、63 个组件目录，无空目录）。

4. **GPL-2.0-only 与 GPL-3.0 不兼容。** 两者不能合并成同一作品。这直接影响 MacStack
   自身代码可选什么许可证——见下。

## 五、需要法律判断的问题

- **MacStack 与 MariaDB 是「聚合」还是「单一作品」？** 从技术上看是聚合：
  MacStack 以**子进程**方式启动 `mariadbd`，通过 socket 通信，两者不链接、不共享地址空间。
  聚合是常见判断，但最终应由法律确认——这个判断决定了 MacStack 自身代码是否必须也是 GPL。
- **`LicenseRef-*` 标识符**（PHP 与 phpMyAdmin 的表达式里出现，例如
  `LicenseRef-Homebrew-public-domain`）是 Homebrew 内部标识符，**不在 SPDX 列表中**。
  需要确认它们对应的实际条款。
- **PHP 表达式里的 LGPL-2.1-only / LGPL-2.1-or-later**：PHP 自身是多许可证混合，
  需要确认随包分发的具体文件分别适用哪些条款。

## 六、MacStack 自身代码的可选方案

| 方案 | 影响 |
|---|---|
| **MIT** | 最简洁、最常见。允许他人自由使用与再分发，无专利条款。 |
| **Apache-2.0** | 同为宽松许可，额外包含明确的专利授权与商标条款。与随包分发的 Apache-2.0 组件一致。 |
| **MPL-2.0** | 文件级 copyleft：修改过的文件需开源，新增文件可闭源。 |
| **GPL-3.0** | 强 copyleft。**若第五节判定为「单一作品」，会与 MariaDB 的 GPL-2.0-only 冲突。** |
| **暂不授权** | 保持现状，但必须在 README 里写清楚，不能一边说「欢迎参与」一边不授权。 |

## 七、建议的下一步

1. 先取得法律意见，确认第五节的三处判断。
2. 由项目所有者选定许可证，加入 `LICENSE` 文件，并在 README 里标注。
3. **无论选哪个**，都要补上 GPL-2.0 的源码提供义务——这是第四节里唯一还没做的确定义务。
   可行做法：在发行页同时提供 MariaDB 与 phpMyAdmin 的对应源码（或指向上游同版本的下载地址），
   并在发行说明里写明。
4. 在 `scripts/package-release.sh` 里加一步检查：发布前确认 `LICENSE` 存在、
   `licenses/THIRD-PARTY.md` 已生成、源码提供指引已就位。**把合规变成构建流程的一部分，
   而不是靠人记得。**
