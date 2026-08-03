#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
derived_data="$repo_root/.DerivedData"
products_dir="$repo_root/Builds"
product="$derived_data/Build/Products/Debug/Droppy.app"
output="$products_dir/Droppy.app"

mkdir -p "$products_dir"

xcodebuild \
    -project "$repo_root/MissionControl.xcodeproj" \
    -scheme Droppy \
    -configuration Debug \
    -destination "platform=macOS,arch=arm64" \
    -derivedDataPath "$derived_data" \
    CODE_SIGNING_ALLOWED=NO \
    build

staging_dir="$(mktemp -d "$products_dir/.droppy-stage.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT

ditto "$product" "$staging_dir/Droppy.app"
rm -rf "$output"
mv "$staging_dir/Droppy.app" "$output"

launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$launch_services" -u "$product" >/dev/null 2>&1 || true
rm -rf "$product"
"$launch_services" -f -R -trusted "$output"

echo "$output"
