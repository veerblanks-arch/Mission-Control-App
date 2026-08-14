#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
derived_data="$repo_root/.DerivedData"
products_dir="$repo_root/Builds"
product="$derived_data/Build/Products/Debug/Droppy.app"
output="$products_dir/Droppy.app"
renamed_output="$products_dir/MissionControl.app"
output_executable="$output/Contents/MacOS/Droppy"
output_pattern="${output_executable//./\\.}"
expected_identifier="com.ranveer.droppy"
expected_team="BCWV7DNVVB"
expected_keychain_group="$expected_team.$expected_identifier"

verify_silverdeck_signature() {
    local app_path="$1"
    local signature_details
    local entitlements

    codesign --verify --deep --strict "$app_path"

    signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1)"
    if [[ "$signature_details" != *"Identifier=$expected_identifier"* ]] ||
        [[ "$signature_details" != *"TeamIdentifier=$expected_team"* ]]; then
        echo "Silverdeck has an unexpected signing identity." >&2
        return 1
    fi

    entitlements="$(codesign -d --entitlements - "$app_path" 2>/dev/null)"
    if [[ "$entitlements" != *"[Key] com.apple.application-identifier"* ]] ||
        [[ "$entitlements" != *"[Key] keychain-access-groups"* ]] ||
        [[ "$entitlements" != *"[String] $expected_keychain_group"* ]]; then
        echo "Silverdeck is missing its private Keychain entitlement." >&2
        return 1
    fi
}

if pgrep -f "^${output_pattern}([[:space:]]|$)" >/dev/null 2>&1; then
    echo "Silverdeck is currently running from $output" >&2
    echo "Quit it normally before rebuilding, or use ./Scripts/run-debug.sh." >&2
    exit 1
fi

mkdir -p "$products_dir"

xcodebuild \
    -project "$repo_root/MissionControl.xcodeproj" \
    -scheme MissionControl \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$derived_data" \
    build

verify_silverdeck_signature "$product"

staging_dir="$(mktemp -d "$products_dir/.mission-control-stage.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

ditto "$product" "$staging_dir/Droppy.app"
verify_silverdeck_signature "$staging_dir/Droppy.app"
rm -rf "$output"
mv "$staging_dir/Droppy.app" "$output"

launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$launch_services" -u "$product" >/dev/null 2>&1 || true
rm -rf "$product"
if [[ -d "$renamed_output" ]]; then
    "$launch_services" -u "$renamed_output" >/dev/null 2>&1 || true
    rm -rf "$renamed_output"
fi
"$launch_services" -f -R -trusted "$output"

echo "$output"
