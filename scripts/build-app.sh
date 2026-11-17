#!/usr/bin/env bash
# Build BusySign.app (release, ad hoc signed) with the SwiftPM toolchain alone.
# Usage: scripts/build-app.sh [--disable-sandbox] --output <path/BusySign.app>
set -euo pipefail

usage() {
    echo "usage: $0 [--disable-sandbox] --output <path/BusySign.app>" >&2
    exit 2
}

output=""
swift_flags=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --disable-sandbox) swift_flags+=(--disable-sandbox); shift ;;
        --output)
            [[ $# -ge 2 ]] || usage
            output="$2"; shift 2 ;;
        *) usage ;;
    esac
done
[[ -n "$output" ]] || usage

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="$(tr -d '[:space:]' < VERSION)"
source_version="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/BusySignCore/Version.swift)"
if [[ "$version" != "$source_version" ]]; then
    echo "error: VERSION ($version) differs from Version.current ($source_version)" >&2
    exit 1
fi

# The SDK in effect (Homebrew may set SDKROOT itself) can need the SwiftUI macro plugin, which Command Line Tools 27.2
# do not ship; pick-sdk.sh then names an older SDK of the same developer dir that builds without it.
developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
current_sdk="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
picked_sdk="$(scripts/pick-sdk.sh "$developer_dir" "$current_sdk")"
if [[ "$picked_sdk" != "$current_sdk" ]]; then
    current_name="$(basename "$(cd "$current_sdk" && pwd -P)")"
    echo "note: building against $(basename "$picked_sdk")" \
        "($current_name needs the SwiftUI macro plugin, missing from $developer_dir)"
    export SDKROOT="$picked_sdk"
fi

swift build -c release --product BusySign ${swift_flags[@]+"${swift_flags[@]}"}
bin_dir="$(swift build -c release --product BusySign --show-bin-path ${swift_flags[@]+"${swift_flags[@]}"})"

if [[ -e "$output" ]]; then
    case "$output" in
        *.app) rm -r "$output" ;;
        *) echo "error: refusing to replace non-.app path $output" >&2; exit 1 ;;
    esac
fi
mkdir -p "$output/Contents/MacOS" "$output/Contents/Resources"
cp "$bin_dir/BusySign" "$output/Contents/MacOS/BusySign"
cp Resources/AppIcon.icns "$output/Contents/Resources/AppIcon.icns"
sed "s/@VERSION@/$version/g" Resources/Info.plist.template > "$output/Contents/Info.plist"

plutil -lint "$output/Contents/Info.plist"
codesign --force --sign - "$output"
echo "built $output ($version)"
