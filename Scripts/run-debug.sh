#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

pkill -x Droppy 2>/dev/null || true
"$script_dir/build-debug.sh"
open -n "$repo_root/Builds/Droppy.app" --args "$@"
