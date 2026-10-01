#!/bin/sh
# 让当前仓库使用 .githooks/ 里的钩子。
#
# 钩子必须放在版本控制里才能被 clone 的人拿到，而 Git 只会执行 .git/hooks/，
# 所以用 core.hooksPath 把位置指过去（这是本地配置，每个克隆各跑一次）。
set -e

root="$(git rev-parse --show-toplevel)"
git -C "$root" config core.hooksPath .githooks
chmod +x "$root/.githooks/pre-commit" "$root/.githooks/pre-push" 2>/dev/null || true

echo "▸ 已启用 pre-commit 钩子（core.hooksPath=.githooks）"
echo "  它会在每次 git commit 前扫描 staged 内容里的密钥 / 个人信息。"
echo "  另外 pre-push 只允许把 main 与 tag 推到发布仓库（origin），"
echo "  存档仓库（vault）不接受直接推送，同步请用：scripts/sync-vault.sh"
echo "  临时绕过：git commit --no-verify    关闭：git config --unset core.hooksPath"
echo "  完整检查（含文档漂移）：python3 scripts/security-scan.py"
