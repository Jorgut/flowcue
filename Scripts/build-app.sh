#!/bin/zsh

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_directory="$(cd -- "$script_directory/.." && pwd -P)"
configuration="${1:-release}"
code_sign_identity="${FLOWCUE_CODE_SIGN_IDENTITY:--}"

sign_bundle() {
    local target="$1"
    local entitlement_mode="${2:-none}"
    local -a sign_arguments

    sign_arguments=(--force --sign "$code_sign_identity")
    if [[ "$entitlement_mode" == "entitlements" && -n "${FLOWCUE_MAC_ENTITLEMENTS:-}" ]]; then
        sign_arguments+=(--entitlements "$FLOWCUE_MAC_ENTITLEMENTS")
    fi
    if [[ "$code_sign_identity" == "-" ]]; then
        sign_arguments+=(--timestamp=none)
    else
        sign_arguments+=(--options runtime --timestamp)
    fi

    codesign "${sign_arguments[@]}" "$target"
}

run_swift_build() {
    if [[ "${CODEX_IDEA_DOCK_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
        swift build "$@" --disable-sandbox
    else
        swift build "$@"
    fi
}

cd "$project_directory"
dist_directory="$project_directory/dist"
app_directory="$dist_directory/FlowCue.app"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$project_directory/Support/Info.plist")"

mkdir -p "$dist_directory"
while IFS= read -r -d '' candidate_app; do
    if [[ "$candidate_app" == "$app_directory" ]]; then
        continue
    fi
    candidate_plist="$candidate_app/Contents/Info.plist"
    [[ -f "$candidate_plist" ]] || continue
    candidate_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$candidate_plist" 2>/dev/null || true)"
    if [[ "$candidate_identifier" == "$bundle_identifier" ]]; then
        printf '%s\n' "Refusing to build while another app with bundle ID $bundle_identifier exists: $candidate_app" >&2
        printf '%s\n' "Move that legacy app out of dist or convert it to a non-runnable archive first." >&2
        exit 1
    fi
done < <(find "$dist_directory" -maxdepth 1 -type d -name '*.app' -print0)

mkdir -p "$project_directory/.build/flowcue-icon-module-cache"
swift \
    -module-cache-path "$project_directory/.build/flowcue-icon-module-cache" \
    "$script_directory/render-flowcue-icon.swift"

run_swift_build --configuration "$configuration" --product CodexIdeaDock
run_swift_build --configuration "$configuration" --product CodexIdeaDockProcessLauncher

binary_directory="$(run_swift_build --configuration "$configuration" --show-bin-path)"
staging_directory="$(mktemp -d "$dist_directory/.flowcue-build.XXXXXX")"
staged_app_directory="$staging_directory/FlowCue.app"
contents_directory="$staged_app_directory/Contents"
backup_app_directory="$dist_directory/.FlowCue.app.previous.$$"

cleanup() {
    rm -rf "$staging_directory"
}
trap cleanup EXIT

mkdir -p "$contents_directory/MacOS" "$contents_directory/Helpers" "$contents_directory/Resources"
cp "$binary_directory/CodexIdeaDock" "$contents_directory/MacOS/CodexIdeaDock"
cp \
    "$binary_directory/CodexIdeaDockProcessLauncher" \
    "$contents_directory/Helpers/CodexIdeaDockProcessLauncher"
cp "$project_directory/Support/Info.plist" "$contents_directory/Info.plist"
if [[ -n "${FLOWCUE_MAC_BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $FLOWCUE_MAC_BUNDLE_ID" "$contents_directory/Info.plist"
fi
if [[ -n "${FLOWCUE_MAC_PROVISIONING_PROFILE:-}" ]]; then
    cp "$FLOWCUE_MAC_PROVISIONING_PROFILE" "$contents_directory/embedded.provisionprofile"
fi
cp "$project_directory/Support/PrivacyInfo.xcprivacy" "$contents_directory/Resources/PrivacyInfo.xcprivacy"
cp "$project_directory/Support/FlowCue.icns" "$contents_directory/Resources/FlowCue.icns"
cp \
    "$project_directory/Support/FlowCueMenuTemplate.png" \
    "$project_directory/Support/FlowCueMenuTemplate@2x.png" \
    "$contents_directory/Resources/"
plutil -lint "$contents_directory/Info.plist"
plutil -lint "$contents_directory/Resources/PrivacyInfo.xcprivacy"
sign_bundle "$contents_directory/Helpers/CodexIdeaDockProcessLauncher" none
sign_bundle "$contents_directory/MacOS/CodexIdeaDock" entitlements
sign_bundle "$staged_app_directory" entitlements
codesign --verify --deep --strict "$staged_app_directory"

if [[ -e "$backup_app_directory" ]]; then
    printf '%s\n' "Unexpected backup path already exists: $backup_app_directory" >&2
    exit 1
fi

if [[ -d "$app_directory" ]]; then
    mv "$app_directory" "$backup_app_directory"
fi

if ! mv "$staged_app_directory" "$app_directory"; then
    if [[ -d "$backup_app_directory" ]]; then
        mv "$backup_app_directory" "$app_directory"
    fi
    exit 1
fi

if [[ -d "$backup_app_directory" ]]; then
    rm -rf "$backup_app_directory"
fi

echo "$app_directory"
