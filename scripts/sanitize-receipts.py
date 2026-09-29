#!/usr/bin/env python3
"""把回执（receipt）里的绝对路径改写成仓库相对路径。

管两类：visual-check 的浏览器证据，以及 deliver 的交付回执（docs/archify/*.deliver.json）。

`archify visual-check` 会把 `artifact.path`、`deliver --json` 会把 `input`/`output` 
写成绝对路径，形如
`/Users/<你>/Developer/Lumi/docs/lumi-architecture.html`。直接提交就等于把家目录
（也就是你的用户名）写进仓库——守卫的 `personal/home-path` 规则会因此报错，
这个脚本就是那个报错的修复动作。

只改 `…/docs/…` 这种指向仓库内文件的字符串，其它字段（sha256、视口、主题）不动，
所以 receipt 与 HTML 的指纹校验依然成立。幂等，可以重复跑。

    python3 scripts/sanitize-receipts.py            # 就地改写两类回执
    python3 scripts/sanitize-receipts.py --check     # 只报告，不写（CI 用）
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ABSOLUTE_DOC_PATH = re.compile(r'"(?:/[^"]*?)/(docs/[^"]+)"')


def sanitize(path: Path, check_only: bool) -> bool:
    """返回 True 表示这个文件需要（或已经）被改写。"""
    original = path.read_text(encoding="utf-8")
    updated = ABSOLUTE_DOC_PATH.sub(r'"\1"', original)
    if updated == original:
        return False
    if not check_only:
        path.write_text(updated, encoding="utf-8")
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="receipt 绝对路径 -> 仓库相对路径")
    parser.add_argument("--check", action="store_true", help="只检查，不改写")
    parser.add_argument("--root", default=None)
    args = parser.parse_args(argv)

    root = Path(args.root).resolve() if args.root else ROOT
    # 两类回执都会写绝对路径：浏览器证据（visual-check）与交付回执（deliver）。
    receipts = sorted((root / "docs").glob("*.visual-check.json"))
    receipts += sorted((root / "docs" / "archify").glob("*.deliver.json"))
    if not receipts:
        print("没有找到 receipt，无事可做")
        return 0

    changed = [receipt for receipt in receipts if sanitize(receipt, args.check)]
    verb = "需要改" if args.check else "已改写"
    if not changed:
        print(f"✓ {len(receipts)} 个 receipt（visual-check + deliver）都已是仓库相对路径")
        return 0
    for receipt in changed:
        print(f"{verb}：{receipt.relative_to(root)}")
    if args.check:
        print("\n→ 跑一次 python3 scripts/sanitize-receipts.py 修掉，再提交")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
