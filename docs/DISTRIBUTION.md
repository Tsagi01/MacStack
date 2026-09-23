# MacStack 分发说明

## 当前分发形态

0.10 的发行包内含版本化 ARM64 Apache、PHP、MariaDB、phpMyAdmin 和递归动态库依赖。最终用户运行核心环境不需要安装 Homebrew；未嵌入运行时的源码开发包仍可使用 `/opt/homebrew` 回退。

发布构建机先运行：

```bash
bash scripts/build-portable-runtime.sh
```

该步骤目前用构建机上的固定 Homebrew keg 作为上游组件来源，生成 `runtime/stage/`，改写动态库为 `@rpath` 并拒绝任何残留的 `/opt/homebrew` 或 `/usr/local` 链接。生成物不提交 Git。

运行：

```bash
bash scripts/package-release.sh
```

会在 `dist/releases` 生成 ARM64 DMG、ZIP 和 SHA-256 校验文件。没有开发者证书时得到的是本地测试包，不应称为已公证正式版。

## 发行前必须先齐备的材料

`scripts/package-release.sh` 会在打包**之前**检查三项合规材料：

| 文件 | 缺了会怎样 |
|---|---|
| `LICENSE` | 项目没有许可证，默认是「保留所有权利」，等于未授权他人使用与再分发 |
| `licenses/THIRD-PARTY.md` | 第三方组件清单未生成，署名与许可证正文没有随包 |
| `docs/SOURCE_OFFER.md` | GPL-2.0 要求的源码提供说明未就位 |

**本地测试打包只警告并继续；设置了 `MACSTACK_NOTARY_PROFILE`（即正式对外发行）时直接中止。**
把合规做成构建流程的一部分，而不是靠人记得。

另外，发行包的文件名取自 `Resources/Info.plist` 的 `CFBundleShortVersionString`。
打标签前先同步它，并更新 `CHANGELOG.md`——`.github/workflows/release.yml` 会检查
标签与 plist 版本是否一致，不一致直接失败。

## Developer ID 与公证

先在 Apple Developer 账户创建 Developer ID Application 证书，并用 `notarytool store-credentials` 保存钥匙串配置。随后：

```bash
MACSTACK_DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
MACSTACK_NOTARY_PROFILE="macstack-notary" \
bash scripts/package-release.sh
```

脚本会重新签名应用、提交 ZIP 公证、装订票据，再创建并签名、公证 DMG。证书、Team ID 和公证凭据不会写入仓库。

## 尚未伪装成已完成的部分

- 便携运行时首版已能独立启动；仍需把构建来源从本机 keg 提升为带校验和、从上游源码可复现的 CI 构建，并逐项复核第三方许可证清单。
- 自动更新需要稳定 HTTPS 发布地址、签名更新清单和回滚策略；在发布基础设施存在前，应用不假装能自动更新。
- ProFTPD 不是动态 PHP 课程的必要条件，默认不安装或暴露 FTP 端口；检测页会显示它是否存在。
