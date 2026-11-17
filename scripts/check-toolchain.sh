#!/usr/bin/env bash
# Fail unless `xcrun --find swift` resolves inside <developer-dir> (e.g. after xcode-select -s of Command Line Tools).
# Usage: scripts/check-toolchain.sh <developer-dir>   (prints the swift path)
set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "usage: $0 <developer-dir>" >&2
    exit 2
fi
dir="$1"
[[ "$dir" == / ]] || dir="${dir%/}"

if ! swift_path="$(xcrun --find swift)"; then
    echo "error: xcrun --find swift failed" >&2
    exit 1
fi
echo "swift: $swift_path"
if [[ "$swift_path" != "$dir"/* ]]; then
    echo "error: swift is '$swift_path', not inside $dir" >&2
    exit 1
fi
