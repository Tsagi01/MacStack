#!/usr/bin/env python3
"""生成便携运行时的第三方许可证清单，并为缺文件的组件补上 vendored 正文。

由 collect-runtime-licenses.sh 调用，不单独运行。

为什么需要它：并非每个 Homebrew 组件的安装目录里都带许可证文件
（实测闭包里 ca-certificates、sqlite、tidy-html5 全深度都没有）。
对这类组件，从 vendor/spdx 取对应 SPDX 正文补齐；取不到的**让构建失败并列出清单**，
不静默留空 —— 静默留空正是之前 licenses/ 下 59 个空目录的成因。
"""

import json
import pathlib
import shutil
import subprocess
import sys

# SPDX 表达式里的连接词。按这些切分出原子标识符。
SEPARATORS = (" AND ", " OR ", " WITH ")


def atomize(expression):
    """把 `A AND B OR C` 这样的表达式拆成原子标识符列表。"""
    if not expression:
        return []
    tokens = [expression]
    for separator in SEPARATORS:
        expanded = []
        for token in tokens:
            expanded.extend(token.split(separator))
        tokens = expanded
    atoms = []
    for token in tokens:
        cleaned = token.strip().strip("()")
        if cleaned and cleaned not in atoms:
            atoms.append(cleaned)
    return atoms


def formula_directory_name(formula):
    """与 shell 侧的目录命名保持一致（tap 限定名里的 / 换成 _）。"""
    return formula.replace("/", "_")


def main():
    brew, licenses_dir, vendor_dir, *formulas = sys.argv[1:]
    licenses = pathlib.Path(licenses_dir)
    vendor = pathlib.Path(vendor_dir)

    raw = subprocess.run(
        [brew, "info", "--json=v2", *formulas],
        capture_output=True, text=True, check=True,
    ).stdout
    info = {entry["name"]: entry for entry in json.loads(raw)["formulae"]}

    rows = []
    from_spdx = []
    unresolved = []

    for formula in formulas:
        directory = licenses / formula_directory_name(formula)
        collected = sorted(p for p in directory.rglob("*") if p.is_file()) if directory.is_dir() else []
        entry = info.get(formula, {})
        version = entry.get("versions", {}).get("stable", "未知")
        expression = entry.get("license") or "未声明"

        if collected:
            note = ""
        else:
            atoms = atomize(entry.get("license"))
            if not atoms:
                unresolved.append((formula, "公式未声明许可证，且组件目录里没有许可证文件"))
                note = ""
            else:
                missing_atoms = [a for a in atoms if not (vendor / f"{a}.txt").is_file()]
                if missing_atoms:
                    unresolved.append((formula, "vendor/spdx 缺少：" + ", ".join(missing_atoms)))
                    note = ""
                else:
                    directory.mkdir(parents=True, exist_ok=True)
                    for atom in atoms:
                        shutil.copyfile(vendor / f"{atom}.txt", directory / f"{atom}.txt")
                    (directory / "SOURCE.txt").write_text(
                        "本组件在 Homebrew 安装目录里没有附带许可证文件，\n"
                        "以下正文取自 SPDX license list，版本见 vendor/spdx/README.md：\n"
                        + "".join(f"  {atom}.txt\n" for atom in atoms),
                        encoding="utf-8",
                    )
                    from_spdx.append(formula)
                    note = "取自 SPDX"

        rows.append((formula, version, expression, note))

    lines = [
        "# 第三方组件与许可证",
        "",
        "本文件由 `scripts/collect-runtime-licenses.sh` 生成，请勿手工编辑。",
        "",
        "便携运行时包含以下组件及其依赖。各组件自带的许可证与声明文件已按组件名",
        "收录在 `licenses/<组件>/` 下；`licenses/sbom/` 是 Homebrew 生成的 SPDX SBOM。",
        "",
        "| 组件 | 版本 | SPDX 标识符 | 正文来源 |",
        "|---|---|---|---|",
    ]
    for formula, version, expression, note in rows:
        lines.append(f"| `{formula}` | {version} | {expression} | {note or '组件自带'} |")
    lines.append("")

    if from_spdx:
        lines += [
            "## 从 SPDX 补齐正文的组件",
            "",
            "这些组件的安装目录里没有任何许可证文件，正文取自 SPDX license list"
            "（版本见 `vendor/spdx/README.md`）：",
            "",
        ]
        lines += [f"- `{formula}`" for formula in from_spdx]
        lines.append("")

    lines += [
        "## 需要人工或法务复核的事项",
        "",
        "本清单只保证「声明与正文已随包提供」，**不构成合规结论**。至少以下几条需要单独审核：",
        "",
        "- `mariadb@11.4` 为 `GPL-2.0-only`。MacStack 以独立进程方式调用其服务端与客户端，",
        "  但 MariaDB 的 Licensing FAQ 指出判断「应用是否必须依赖服务器才能工作」还有进一步条件，",
        "  「独立进程」本身不构成免于 GPL 义务的充分条件。",
        "- `php@8.2` 的许可证表达式包含 `LGPL-2.1-only` 与 `LGPL-2.1-or-later`，",
        "  动态链接场景下的义务需逐条核对。",
        "- `runtime/lib` 下扁平化的动态库来自上述依赖闭包，各自的上游许可证以本表为准。",
        "- 表达式中的 `LicenseRef-*` 是 Homebrew 内部标识符，不在 SPDX 列表中，需单独确认。",
        "",
    ]

    (licenses / "THIRD-PARTY.md").write_text("\n".join(lines), encoding="utf-8")

    print(f"  组件总数：{len(rows)}")
    print(f"  组件自带许可证文件：{len(rows) - len(from_spdx)}")
    print(f"  从 SPDX 补齐：{len(from_spdx)}" + (f"（{', '.join(from_spdx)}）" if from_spdx else ""))
    print(f"  清单：{licenses / 'THIRD-PARTY.md'}")

    if unresolved:
        print("", file=sys.stderr)
        print("portable-runtime: 以下组件没有任何许可证正文，且无法从 vendor/spdx 补齐：", file=sys.stderr)
        for formula, reason in unresolved:
            print(f"  - {formula}：{reason}", file=sys.stderr)
        print(
            "请运行 scripts/refresh-license-texts.sh 补齐，或确认该组件确实无需随附许可证。",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
