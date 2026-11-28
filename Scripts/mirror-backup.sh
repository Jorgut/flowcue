#!/bin/zsh
# 把本地全部分支与 tag 镜像到私有备份仓库（只增不删）。
set -euo pipefail
cd "$(dirname "$0")/.."

git push backup 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*' "$@"

echo
echo "本地分支 / 备份分支："
printf '  %s / %s\n' "$(git for-each-ref refs/heads | wc -l | tr -d ' ')" \
    "$(git ls-remote --heads backup | wc -l | tr -d ' ')"
missing=0
while read -r b; do
    git ls-remote --heads backup "$b" | grep -q . || { echo "  ⚠️  备份缺少：$b"; missing=1; }
done < <(git for-each-ref --format='%(refname:short)' refs/heads)
[ "$missing" = 0 ] && echo "  ✅ 每条本地分支都有备份"
