# 第三方源码提供说明

> 这份文件是给**分发**用的：随包分发 GPL 许可的二进制时，按 GPL-2.0 第 3 条需要同时提供
> 对应的完整源码，或提供有效期不少于三年的书面要约。
>
> **当前状态：草稿。** 下面的地址与校验和来自本机构建时使用的 Homebrew 公式（可用
> `brew cat <公式名>` 复核），但**尚未经过发布流程验证**。第一次公开分发前必须逐条确认。

## 一、为什么需要这份文件

`licenses/` 满足的是**署名与许可证正文随包**。GPL 还额外要求**源码可获取**。
这两件事不能互相替代——只附许可证正文不构成对 GPL 的遵守。

## 二、随包分发的主要组件

版本号与 `runtime/manifest.json` 保持一致。

| 组件 | 版本 | 许可证 | 源码 |
|---|---|---|---|
| MariaDB | 11.4.13 | GPL-2.0-only | `https://archive.mariadb.org/mariadb-11.4.13/source/mariadb-11.4.13.tar.gz` |
| phpMyAdmin | 5.2.3 | GPL-2.0 等 | `https://files.phpmyadmin.net/phpMyAdmin/5.2.3/phpMyAdmin-5.2.3-all-languages.tar.gz` |
| Apache httpd | 2.4.68 | Apache-2.0 | `https://www.apache.org/dyn/closer.lua?path=httpd/httpd-2.4.68.tar.bz2` |
| PHP | 8.2.33 | PHP-3.01 等 | `https://www.php.net/distributions/php-8.2.33.tar.xz` |

校验和（SHA-256，取自构建时的 Homebrew 公式）：

```
1bb254b106d0a7ca871cfa18fa6e18d4b80a7430f9ec9d1571ec4271a13def96  mariadb-11.4.13.tar.gz
12ba1c425fa4071abbd4e7668c9ebdeac0b0755a467a6d6d5026122bb47c102b  phpMyAdmin-5.2.3-all-languages.tar.gz
68c74d4df38c26bed4dfbdb8f3baf1eb532f3872357becc1bba5d136f6b63c06  httpd-2.4.68.tar.bz2
fbdeace9b38220436a4c8fd79b900df92878151db145e641750743a283b514c1  php-8.2.33.tar.xz
```

其中 **MariaDB 与 phpMyAdmin 是 GPL 许可，源码提供义务直接适用**。
httpd 与 PHP 是宽松许可，列出源码是为了完整，不构成强制义务。

## 三、随包分发的动态库

`runtime/stage/lib/` 下有 60 个动态库，其中带 copyleft 的包括
`liblzo2.2.dylib`（GPL-2.0-or-later）、`libaspell.15.dylib`（LGPL-2.1-only）、
`libgroonga.0.0.0.dylib`（LGPL-2.1-or-later）、`libmariadb.3.dylib`（LGPL-2.1）、
`libintl.8.dylib`（LGPL-2.1-or-later）、`libltdl.7.dylib`（LGPL-2.1-or-later）、
`libgmp.10.dylib`（LGPL-3.0-or-later 或 GPL-2.0-or-later）、
`libodbc.2.dylib`（LGPL-2.1-or-later 和 GPL-2.0-or-later）。

**取得每个库的准确源码地址的方法**：组件清单见 `licenses/THIRD-PARTY.md`，
每个组件对应的公式可用 `brew cat <公式名>` 读出 `url` 与 `sha256`。

发布流程应当在**打包时**把这份清单生成出来，而不是手工维护——手工维护一定会过期。
（见 `scripts/package-release.sh` 里的发行前检查。）

## 四、如何向用户提供

在 GitHub Release 说明里附上本文档的链接，并写明：

> 本发行版包含 MariaDB 11.4.13（GPL-2.0-only）与 phpMyAdmin 5.2.3（GPL-2.0）的二进制。
> 对应源码可从上文所列地址获取；如地址失效，可在本项目 issue 中提出，我们会提供副本。

最后一句是 GPL-2.0 第 3 条(b)所说的**书面要约**——它是「地址失效」时的兜底，
不能省略。

## 五、每次发布要做的事

1. 更新第二节的版本号与地址（对照 `runtime/manifest.json`）。
2. 重新计算校验和（`brew cat <公式名> | grep sha256`）。
3. 确认 `licenses/THIRD-PARTY.md` 已重新生成，且没有空目录
   （`scripts/verify-portable-runtime.sh` 会检查）。
4. 确认本文件的「当前状态」已从草稿改为已核实。
5. 跑 `scripts/package-release.sh`——它会在正式发行前检查上述材料是否齐备。
