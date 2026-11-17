#!/usr/bin/env bash
# Check a release tag: it equals v + VERSION, VERSION equals Version.current, and its commit is on main.
# Usage: scripts/check-release.sh <tag> <main-ref>   (VERSION from BUSYSIGN_ROOT, default repo root; git runs in cwd)
set -euo pipefail

usage() {
    echo "usage: $0 <tag> <main-ref>" >&2
    exit 2
}

fail() {
    echo "error: $*" >&2
    exit 1
}

[[ $# -eq 2 && -n "$1" && -n "$2" && "$1" != -* && "$2" != -* ]] || usage
tag="$1"
main_ref="$2"
root="${BUSYSIGN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
swift_file="$root/Sources/BusySignCore/Version.swift"

[[ -f "$root/VERSION" ]] || fail "$root/VERSION not found"
[[ -f "$swift_file" ]] || fail "$swift_file not found"
version="$(tr -d '[:space:]' < "$root/VERSION")"
source_version="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$swift_file")"

version_re='^[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$version" =~ $version_re ]] || fail "VERSION ($version) is not X.Y.Z"
[[ "$tag" == "v$version" ]] || fail "tag $tag does not match VERSION (want v$version)"
[[ "$version" == "$source_version" ]] || fail "VERSION ($version) differs from Version.current ($source_version)"

git rev-parse --git-dir > /dev/null 2>&1 || fail "$(pwd) is not in a git repository"
tag_commit="$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}")" || fail "tag $tag not found"
main_commit="$(git rev-parse --verify --quiet "$main_ref^{commit}")" || fail "main ref $main_ref not found"
short="$(git rev-parse --short "$tag_commit")"
if ! git merge-base --is-ancestor "$tag_commit" "$main_commit"; then
    fail "tag $tag ($short) is not on main: not an ancestor of $main_ref"
fi
echo "release $tag ok: VERSION and Version.current are $version, $short is on $main_ref"
