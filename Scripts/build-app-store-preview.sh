#!/bin/zsh

set -euo pipefail

script_directory="$(cd -- "$(dirname -- "$0")" && pwd -P)"
project_directory="$(cd -- "$script_directory/.." && pwd -P)"
configuration="${1:-release}"
bundle_identifier="${REROUTE_APP_STORE_BUNDLE_IDENTIFIER:-}"

if [[ -z "$bundle_identifier" ]]; then
    printf '%s\n' "REROUTE_APP_STORE_BUNDLE_IDENTIFIER is required." >&2
    exit 1
fi

if [[ ! "$bundle_identifier" =~ ^[A-Za-z0-9.-]+$ ]]; then
    printf '%s\n' "REROUTE_APP_STORE_BUNDLE_IDENTIFIER contains unsupported characters." >&2
    exit 1
fi

run_swift_build() {
    if [[ "${CODEX_IDEA_DOCK_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
        swift build "$@" --disable-sandbox
    else
        swift build "$@"
    fi
}

cd "$project_directory"
dist_directory="$project_directory/dist"
app_directory="$dist_directory/Reroute-App-Store-Preview.app"

mkdir -p "$dist_directory"
mkdir -p "$project_directory/.build/reroute-icon-module-cache"
swift \
    -module-cache-path "$project_directory/.build/reroute-icon-module-cache" \
    "$script_directory/render-reroute-icon.swift"

run_swift_build \
    --configuration "$configuration" \
    --product CodexIdeaDock \
    -Xswiftc -DREROUTE_APP_STORE

binary_directory="$(
    run_swift_build \
        --configuration "$configuration" \
        --show-bin-path \
        -Xswiftc -DREROUTE_APP_STORE
)"
staging_directory="$(mktemp -d "$dist_directory/.reroute-app-store-build.XXXXXX")"
staged_app_directory="$staging_directory/Reroute-App-Store-Preview.app"
contents_directory="$staged_app_directory/Contents"
backup_app_directory="$dist_directory/.Reroute-App-Store-Preview.app.previous.$$"

cleanup() {
    rm -rf "$staging_directory"
}
trap cleanup EXIT

mkdir -p "$contents_directory/MacOS" "$contents_directory/Resources"
cp "$binary_directory/CodexIdeaDock" "$contents_directory/MacOS/CodexIdeaDock"
cp "$project_directory/Support/Info.plist" "$contents_directory/Info.plist"
cp "$project_directory/Support/PrivacyInfo.xcprivacy" "$contents_directory/Resources/PrivacyInfo.xcprivacy"
cp "$project_directory/Support/Reroute.icns" "$contents_directory/Resources/Reroute.icns"
cp \
    "$project_directory/Support/RerouteMenuTemplate.png" \
    "$project_directory/Support/RerouteMenuTemplate@2x.png" \
    "$contents_directory/Resources/"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$contents_directory/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSApplicationCategoryType string public.app-category.productivity" "$contents_directory/Info.plist"
/usr/libexec/PlistBuddy -c "Add :ITSAppUsesNonExemptEncryption bool false" "$contents_directory/Info.plist"

plutil -lint "$contents_directory/Info.plist"
plutil -lint "$contents_directory/Resources/PrivacyInfo.xcprivacy"
plutil -lint "$project_directory/Support/AppStore.entitlements"

codesign \
    --force \
    --sign - \
    --timestamp=none \
    --entitlements "$project_directory/Support/AppStore.entitlements" \
    "$staged_app_directory"
codesign --verify --deep --strict "$staged_app_directory"

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

printf '%s\n' "$app_directory"
printf '%s\n' "Local sandbox preview only; App Store signing and upload still require an Xcode archive."
