#!/bin/sh
# 把本地历史同步到公开仓库（public = tianruijia2008/Lumi）。
#
# 为什么不能直接 git push public：公开仓库刻意不含 PUBLIC_EXCLUDE 里的文件（给 AI 代理的
# 约定），而且是从**整段历史**里去掉，所以公开仓库的提交哈希和本地不同，只能重新生成再推：
#
#   1. 把本地的 PUBLIC_BRANCHES 与 tag 克隆到临时目录（其它本地分支一律不带）
#   2. git filter-repo 从每个提交里删掉 PUBLIC_EXCLUDE。结果是确定的：同样的输入每次
#      得到同样的哈希，所以已经推过的提交不会变，推送是快进，不需要 --force
#   3. 公开仓库的两条分支顶上各有一个公开仓库专用提交（去掉指向被删文件的链接），
#      所以是把过滤后的分支**合并**进公开仓库里的同名分支，而不是覆盖它
#   4. 在合并结果上跑完整守卫和守卫自测，都通过才推送
#
# 用法：scripts/sync-public.sh             同步并推送
#       scripts/sync-public.sh --dry-run   只生成、不推送，保留临时目录供检查
# 依赖：git-filter-repo（brew install git-filter-repo）
set -eu

PUBLIC_EXCLUDE="AGENTS.md CLAUDE.md"
PUBLIC_BRANCHES="main backup/pre-public"

dry_run=0
case "${1:-}" in
    --dry-run) dry_run=1 ;;
    "") ;;
    *) echo "用法：$0 [--dry-run]" >&2; exit 2 ;;
esac

command -v git-filter-repo >/dev/null 2>&1 || {
    echo "✗ 需要 git-filter-repo：brew install git-filter-repo" >&2; exit 1; }

root="$(git rev-parse --show-toplevel)"
url="$(git -C "$root" remote get-url public)"
work="$(mktemp -d "${TMPDIR:-/tmp}/lumi-public.XXXXXX")"
keep_work=$dry_run
cleanup() { [ "$keep_work" = 1 ] || /bin/rm -rf "$work"; }
trap cleanup EXIT

echo "▸ 克隆本地历史到 ${work}"
git clone -q --bare --no-local "$root" "$work/repo.git"
cd "$work/repo.git"
for branch in $(git for-each-ref --format='%(refname:short)' refs/heads); do
    case " $PUBLIC_BRANCHES " in
        *" $branch "*) ;;
        *) git branch -q -D "$branch" ;;
    esac
done

echo "▸ 从整段历史里去掉：${PUBLIC_EXCLUDE}"
set --
for file in $PUBLIC_EXCLUDE; do set -- "$@" --path "$file"; done
git filter-repo --quiet --force --invert-paths "$@"

# 每条分支：公开仓库里已有 → 把过滤后的本地分支合并进去（专用提交留在公开仓库那边）；
#           还没有       → 第一次同步，过滤后的历史原样推。
for branch in $PUBLIC_BRANCHES; do
    tree="$work/tree-$(printf '%s' "$branch" | tr / -)"
    if git fetch -q "$url" "+refs/heads/$branch:refs/public/$branch" 2>/dev/null; then
        git worktree add -q --detach "$tree" "refs/public/$branch"
        if git -C "$tree" merge-base --is-ancestor "$branch" HEAD; then
            echo "▸ ${branch}：公开仓库已包含本地最新提交，无需合并"
        elif ! git -C "$tree" merge -q --no-edit \
                -m "sync: 合入 ${branch} $(git rev-parse --short "$branch")" "$branch"; then
            keep_work=1
            echo "✗ ${branch} 合并冲突。请在 ${tree} 里解决并提交，然后在那里执行：" >&2
            echo "  git branch -f ${branch} HEAD && git push ${url} ${branch}" >&2
            exit 1
        fi
        git -C "$tree" branch -f "$branch" HEAD
    else
        echo "▸ ${branch}：公开仓库里还没有这条分支，过滤后的历史原样推上去"
        git worktree add -q "$tree" "$branch"
    fi

    echo "▸ ${branch}：在要公开的内容上跑守卫"
    (cd "$tree" && python3 scripts/security-scan.py >/dev/null) || {
        keep_work=1
        echo "✗ 守卫未通过，没有推送。复现：cd ${tree} && python3 scripts/security-scan.py" >&2
        exit 1; }
    (cd "$tree" && python3 scripts/test-security-scan.py >/dev/null) || {
        keep_work=1
        echo "✗ 守卫自测未通过，没有推送。复现：cd ${tree} && python3 scripts/test-security-scan.py" >&2
        exit 1; }
done

set --
for branch in $PUBLIC_BRANCHES; do set -- "$@" "refs/heads/$branch:refs/heads/$branch"; done
if [ "$dry_run" = 1 ]; then
    echo "▸ --dry-run：没有推送。结果在 ${work}/repo.git（工作区 ${work}/tree）"
    exit 0
fi
echo "▸ 推送到 ${url}"
git -C "$work/repo.git" push "$url" "$@" 'refs/tags/*:refs/tags/*'
echo "✓ 公开仓库已同步"
