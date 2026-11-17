#!/usr/bin/env bash
# Write the release source tarball busysign-<version>.tar.gz (git archive of <rev>) and its .sha256 into <outdir>.
# Usage: scripts/make-release-tarball.sh <rev> <version> <outdir>   (prints the two paths)
set -euo pipefail

usage() {
    echo "usage: $0 <rev> <version> <outdir>" >&2
    exit 2
}

[[ $# -eq 3 && -n "$1" && -n "$3" && "$1" != -* ]] || usage
rev="$1"
version="$2"
outdir="$3"
version_re='^[0-9]+\.[0-9]+\.[0-9]+$'
if [[ ! "$version" =~ $version_re ]]; then
    echo "error: version must be X.Y.Z with digits only, got '$version'" >&2
    exit 2
fi

if ! commit="$(git rev-parse --verify --quiet "$rev^{commit}")"; then
    echo "error: $rev is not a commit" >&2
    exit 1
fi

[[ "$outdir" == / ]] || outdir="${outdir%/}"
name="busysign-$version.tar.gz"
mkdir -p "$outdir"
if ! git archive --format=tar.gz --prefix="busysign-$version/" "$commit" > "$outdir/$name"; then
    rm -f "$outdir/$name"
    echo "error: git archive of $rev failed" >&2
    exit 1
fi
(cd "$outdir" && shasum -a 256 "$name" > "$name.sha256")

echo "$outdir/$name"
echo "$outdir/$name.sha256"
