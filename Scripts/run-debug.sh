#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
app_executable="$repo_root/Builds/Droppy.app/Contents/MacOS/Droppy"
legacy_executable="$repo_root/Builds/MissionControl.app/Contents/MacOS/MissionControl"

# Stop only this repository's app build. A separately installed Droppy
# app may be running and must not be touched.
for executable in "$app_executable" "$legacy_executable"; do
    executable_pattern="${executable//./\\.}"
    pkill -f "^${executable_pattern}([[:space:]]|$)" 2>/dev/null || true
done
"$script_dir/build-debug.sh"
open -n "$repo_root/Builds/Droppy.app" --args "$@"
