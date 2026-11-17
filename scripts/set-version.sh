#!/usr/bin/env bash
# Set the release version in VERSION and in Version.current (Sources/BusySignCore/Version.swift).
# Usage: scripts/set-version.sh X.Y.Z   (BUSYSIGN_ROOT overrides the repository root)
set -euo pipefail

usage() {
    echo "usage: $0 X.Y.Z" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
version="$1"
version_re='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ ! "$version" =~ $version_re ]]; then
    echo "error: version must be X.Y.Z with digits only, got '$version'" >&2
    exit 2
fi

root="${BUSYSIGN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
version_file="$root/VERSION"
swift_file="$root/Sources/BusySignCore/Version.swift"
current_re='static let current = "[^"]*"'

for file in "$version_file" "$swift_file"; do
    if [[ ! -f "$file" ]]; then
        echo "error: $file not found" >&2
        exit 1
    fi
done
matches="$(grep -c "$current_re" "$swift_file" || true)"
if [[ "$matches" != 1 ]]; then
    echo "error: Version.swift ($swift_file) has $matches 'static let current = \"...\"' lines, want 1" >&2
    exit 1
fi

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "s/$current_re/static let current = \"$version\"/" "$swift_file" > "$tmp"
# Copy over the file rather than move, so its permissions stay as they are.
cat "$tmp" > "$swift_file"
printf '%s\n' "$version" > "$version_file"

source_version="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$swift_file")"
if [[ "$source_version" != "$version" ]]; then
    echo "error: Version.current reads '$source_version' after the edit, want $version" >&2
    exit 1
fi
echo "VERSION and Version.current set to $version"
