#!/bin/zsh

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_directory="$(cd -- "$script_directory/.." && pwd -P)"
signing_identity="${FLOWCUE_CODE_SIGN_IDENTITY:-}"
notary_profile="${FLOWCUE_NOTARY_PROFILE:-}"

if [[ -z "$signing_identity" ]]; then
    printf '%s\n' "FLOWCUE_CODE_SIGN_IDENTITY must name a Developer ID Application identity." >&2
    exit 1
fi

if [[ "$signing_identity" != Developer\ ID\ Application:* ]]; then
    printf '%s\n' "Direct downloads must use a Developer ID Application identity." >&2
    exit 1
fi

skip_notarize="${FLOWCUE_SKIP_NOTARIZE:-0}"
if [[ -z "$notary_profile" && "$skip_notarize" != "1" ]]; then
    printf '%s\n' "FLOWCUE_NOTARY_PROFILE must name a notarytool Keychain profile." >&2
    printf '%s\n' "用 FLOWCUE_SKIP_NOTARIZE=1 可以先本地验证签名与打包。" >&2
    exit 1
fi

# 官网自 2026-11-19 起是同一个仓库的 main worktree（push main 触发 Cloudflare 部署）。
# 发布前先校验目标，避免公证跑完才发现改动落在不会部署的分支上。
site_root="${FLOWCUE_SITE_DIR:-}"
if [[ -z "$site_root" ]]; then
    worktree_site="$project_directory/../FlowCue-Worktrees/site"
    if [[ -f "$worktree_site/site/mac/index.html" ]]; then
        site_root="$worktree_site"
    else
        site_root="$project_directory"
    fi
fi
if [[ ! -f "$site_root/site/mac/index.html" ]]; then
    printf '%s\n' "找不到官网页面：$site_root/site/mac/index.html（用 FLOWCUE_SITE_DIR 指定官网 worktree）" >&2
    exit 1
fi
site_root="$(cd "$site_root" && pwd -P)"
if ! git -C "$site_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s\n' "官网目录不是 Git 仓库：$site_root" >&2
    exit 1
fi
site_branch="$(git -C "$site_root" rev-parse --abbrev-ref HEAD)"
if [[ "$site_branch" != "main" ]]; then
    printf '%s\n' "官网 worktree 不在 main（当前 $site_branch），push 不会部署：$site_root" >&2
    exit 1
fi
if [[ -n "$(git -C "$site_root" status --porcelain)" ]]; then
    printf '%s\n' "官网 worktree 有未提交改动，先处理再发版：$site_root" >&2
    git -C "$site_root" status --short >&2
    exit 1
fi

cd "$project_directory"
FLOWCUE_CODE_SIGN_IDENTITY="$signing_identity" zsh "$script_directory/build-app.sh" release

app_path="$project_directory/dist/FlowCue.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
architecture="$(lipo -archs "$app_path/Contents/MacOS/CodexIdeaDock" | tr ' ' '-')"
release_directory="$project_directory/dist/releases"
asset_name="FlowCue-$version-macOS-$architecture.zip"
temporary_archive="$release_directory/.FlowCue-$version-notarization.zip"
release_archive="$release_directory/$asset_name"
checksum_file="$release_archive.sha256"

mkdir -p "$release_directory"
rm -f "$temporary_archive" "$release_archive" "$checksum_file"

codesign --verify --deep --strict --verbose=2 "$app_path"
if [[ "$skip_notarize" == "1" ]]; then
    printf '%s\n' "跳过公证（FLOWCUE_SKIP_NOTARIZE=1）" >&2
else
    ditto -c -k --sequesterRsrc --keepParent "$app_path" "$temporary_archive"
    xcrun notarytool submit "$temporary_archive" \
        --keychain-profile "$notary_profile" \
        --wait
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=2 "$app_path"
fi

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_archive"
(
    cd "$release_directory"
    shasum -a 256 "$asset_name" > "$asset_name.sha256"
)
rm -f "$temporary_archive"

# DMG（用户双击挂载后拖进 Applications）
dmg_path="$release_directory/FlowCue-$version-macOS-$architecture.dmg"
staging="$release_directory/.dmg-staging"

create_dmg() {
    rm -rf "$staging" "$dmg_path"
    mkdir -p "$staging"
    cp -R "$app_path" "$staging/"
    ln -s /Applications "$staging/Applications"
    hdiutil create -quiet -volname "FlowCue" -srcfolder "$staging" -ov -format UDZO "$dmg_path"
    rm -rf "$staging"
    codesign --force --timestamp --sign "$signing_identity" "$dmg_path"
}

# 2026-11-19 实测：中途 kill 过 notarytool 会留下 diskimages-helper 锁住 DMG，
# 之后的提交会卡在 pre-submission checks 或报 “must be a ... UDIF disk image”。
# 这里给提交加 10 分钟上限，失败就重建 DMG 再试一次。
clear_dmg_holders() {
    for pid in $(lsof -t "$dmg_path" 2>/dev/null); do
        kill -9 "$pid" 2>/dev/null || true
    done
}

submit_dmg() {
    perl -e 'alarm shift; exec @ARGV' 600 \
        xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
}

create_dmg

if [[ "$skip_notarize" != "1" ]]; then
    if ! submit_dmg; then
        printf '%s\n' "DMG 公证失败，清理占用后重建再试一次：$dmg_path" >&2
        clear_dmg_holders
        create_dmg
        submit_dmg
    fi
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
fi

(
    cd "$release_directory"
    shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$dmg_path").sha256"
)

# 同步官网下载页：只保留当前版本的 DMG / SHA-256，并更新版本与体积
site_downloads="$site_root/site/downloads"
site_page="$site_root/site/mac/index.html"
mkdir -p "$site_downloads"
dmg_name="$(basename "$dmg_path")"
find "$site_downloads" -maxdepth 1 -type f -name '*.dmg' ! -name "$dmg_name" -delete
find "$site_downloads" -maxdepth 1 -type f -name '*.dmg.sha256' ! -name "$dmg_name.sha256" -delete
cp "$dmg_path" "$site_downloads/"
cp "$dmg_path.sha256" "$site_downloads/"
dmg_size="$(python3 -c "import os,sys; print(f\"{os.path.getsize(sys.argv[1])/1_000_000:.1f} MB\")" "$dmg_path")"
if [[ -f "$site_page" ]]; then
    python3 - "$site_page" "$dmg_name" "$version" "$dmg_size" <<'PYEOF'
import re, sys
page, name, version, size = sys.argv[1:5]
html = open(page, encoding='utf-8').read()
html = re.sub(r'href="/downloads/[^"]+"', f'href="/downloads/{name}"', html)
html = re.sub(r'<span id="ver">[^<]*</span>', f'<span id="ver">{version}</span>', html)
html = re.sub(r'<span id="size">[^<]*</span>', f'<span id="size">{size}</span>', html)
open(page, 'w', encoding='utf-8').write(html)
PYEOF
fi

# 提交并推送站点改动（在 main worktree 内提交），让 Cloudflare 自动部署；
# FLOWCUE_SKIP_SITE_COMMIT=1 只更新文件、不提交
if [[ "${FLOWCUE_SKIP_SITE_COMMIT:-0}" != "1" ]]; then
    site_paths=("site/mac/index.html" "site/downloads")
    if [[ -n "$(git -C "$site_root" status --porcelain -- "${site_paths[@]}")" ]]; then
        git -C "$site_root" add -A -- "${site_paths[@]}"
        git -C "$site_root" commit -m "release(site): FlowCue $version" -- "${site_paths[@]}"
        if ! git -C "$site_root" push origin HEAD; then
            printf '%s\n' "warning: 站点改动已提交但推送失败，请在 $site_root 手动 push main。" >&2
            exit 1
        fi
    fi
else
    printf '%s\n' "note: FLOWCUE_SKIP_SITE_COMMIT=1，官网文件已更新但未提交：$site_root" >&2
fi

printf '%s\n' "$release_archive"
printf '%s\n' "$dmg_path"
printf '%s\n' "$checksum_file"
