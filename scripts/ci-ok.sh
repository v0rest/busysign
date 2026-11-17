#!/usr/bin/env bash
# The ci-ok verdict: scripts and macos must succeed, authors must succeed or be skipped (release tags skip it).
# Usage: scripts/ci-ok.sh <scripts-result> <authors-result> <macos-result>   (needs.<job>.result values)
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <scripts-result> <authors-result> <macos-result>" >&2
    exit 2
fi
scripts="$1"
authors="$2"
macos="$3"

echo "scripts=$scripts authors=$authors macos=$macos"
failed=0
if [[ "$scripts" != success ]]; then
    echo "::error::scripts: $scripts"
    failed=1
fi
if [[ "$authors" != success && "$authors" != skipped ]]; then
    echo "::error::authors: $authors"
    failed=1
fi
if [[ "$macos" != success ]]; then
    echo "::error::macos: $macos"
    failed=1
fi
exit "$failed"
