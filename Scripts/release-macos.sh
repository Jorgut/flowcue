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

printf '%s\n' "$release_archive"
printf '%s\n' "$dmg_path"
printf '%s\n' "$checksum_file"
