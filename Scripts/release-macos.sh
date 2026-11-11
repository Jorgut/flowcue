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

if [[ -z "$notary_profile" ]]; then
    printf '%s\n' "FLOWCUE_NOTARY_PROFILE must name a notarytool Keychain profile." >&2
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
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$temporary_archive"
xcrun notarytool submit "$temporary_archive" \
    --keychain-profile "$notary_profile" \
    --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=2 "$app_path"

ditto -c -k --sequesterRsrc --keepParent "$app_path" "$release_archive"
(
    cd "$release_directory"
    shasum -a 256 "$asset_name" > "$asset_name.sha256"
)
rm -f "$temporary_archive"

printf '%s\n' "$release_archive"
printf '%s\n' "$checksum_file"
