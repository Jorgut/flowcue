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
rm -rf "$staging" "$dmg_path"
mkdir -p "$staging"
cp -R "$app_path" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -quiet -volname "FlowCue" -srcfolder "$staging" -ov -format UDZO "$dmg_path"
rm -rf "$staging"
codesign --force --timestamp --sign "$signing_identity" "$dmg_path"

if [[ "$skip_notarize" != "1" ]]; then
    xcrun notarytool submit "$dmg_path" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg_path"
    xcrun stapler validate "$dmg_path"
fi

(
    cd "$release_directory"
    shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$dmg_path").sha256"
)

# 同步官网下载页：只保留当前版本的 DMG / SHA-256，并更新版本与体积
site_downloads="$project_directory/site/downloads"
site_page="$project_directory/site/mac/index.html"
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

# 提交并推送站点改动，让 Pages 自动部署；FLOWCUE_SKIP_SITE_COMMIT=1 可关闭
if [[ "${FLOWCUE_SKIP_SITE_COMMIT:-0}" != "1" ]] && git -C "$project_directory" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    site_paths=("site/mac/index.html" "site/downloads")
    if [[ -n "$(git -C "$project_directory" status --porcelain -- "${site_paths[@]}")" ]]; then
        git -C "$project_directory" add -A -- "${site_paths[@]}"
        git -C "$project_directory" commit -m "release(site): FlowCue $version" -- "${site_paths[@]}"
        if ! git -C "$project_directory" push origin HEAD; then
            printf '%s\n' "warning: 站点改动已提交但推送失败，请手动 push 后合并到 main 触发部署。" >&2
        fi
    fi
    if [[ "$(git -C "$project_directory" rev-parse --abbrev-ref HEAD)" != "main" ]]; then
        printf '%s\n' "note: 当前分支不是 main，站点改动需合并到 main 后才会自动部署。" >&2
    fi
fi

printf '%s\n' "$release_archive"
printf '%s\n' "$dmg_path"
printf '%s\n' "$checksum_file"
