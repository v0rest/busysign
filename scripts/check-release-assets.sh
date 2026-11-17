#!/usr/bin/env bash
# Check that a release's asset names (one per line on stdin) are exactly busysign-X.Y.Z.tar.gz and its .sha256.
# Usage: gh release view vX.Y.Z --json assets --jq '.assets[].name' | scripts/check-release-assets.sh X.Y.Z
set -euo pipefail

usage() {
    echo "usage: $0 X.Y.Z   (asset names on stdin)" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
version="$1"
version_re='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ ! "$version" =~ $version_re ]]; then
    echo "error: version must be X.Y.Z with digits only, got '$version'" >&2
    exit 2
fi
tar_name="busysign-$version.tar.gz"
sha_name="$tar_name.sha256"

count=0
tar_seen=0
sha_seen=0
extra=""
# The last line may lack a newline; read still returns it in $name.
while IFS= read -r name || [[ -n "$name" ]]; do
    [[ -n "$name" ]] || continue
    count=$((count + 1))
    echo "asset: $name"
    if [[ "$name" == "$tar_name" ]]; then
        tar_seen=$((tar_seen + 1))
    elif [[ "$name" == "$sha_name" ]]; then
        sha_seen=$((sha_seen + 1))
    else
        extra="$extra $name"
    fi
done

failed=0
if [[ $tar_seen -ne 1 ]]; then
    echo "error: $tar_name is listed $tar_seen time(s), want once" >&2
    failed=1
fi
if [[ $sha_seen -ne 1 ]]; then
    echo "error: $sha_name is listed $sha_seen time(s), want once" >&2
    failed=1
fi
if [[ -n "$extra" ]]; then
    echo "error: unexpected asset(s):$extra" >&2
    failed=1
fi
if [[ $failed -ne 0 ]]; then
    echo "error: the release has $count asset(s), want exactly $tar_name and $sha_name" >&2
    exit 1
fi
echo "release assets ok: $tar_name and $sha_name"
