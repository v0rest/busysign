#!/usr/bin/env bash
# The ci-ok verdict: scripts and changes succeed, authors succeeds or is skipped (release tags), macos succeeds or is
# skipped because changes found docs only. Usage: scripts/ci-ok.sh <scripts> <authors> <macos> <changes> <code>
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "usage: $0 <scripts-result> <authors-result> <macos-result> <changes-result> <changes-code>" >&2
    echo "  (needs.<job>.result values, and needs.changes.outputs.code)" >&2
    exit 2
fi
scripts="$1"
authors="$2"
macos="$3"
changes="$4"
code="$5"

echo "scripts=$scripts authors=$authors macos=$macos changes=$changes code=$code"
failed=0
if [[ "$scripts" != success ]]; then
    echo "::error::scripts: $scripts"
    failed=1
fi
if [[ "$authors" != success && "$authors" != skipped ]]; then
    echo "::error::authors: $authors"
    failed=1
fi
if [[ "$changes" != success ]]; then
    echo "::error::changes: $changes"
    failed=1
fi
if [[ "$macos" == success ]]; then
    :
elif [[ "$macos" == skipped && "$changes" == success && "$code" == false ]]; then
    echo "macos skipped: the change is docs only"
else
    echo "::error::macos: $macos (changes=$changes code=$code)"
    failed=1
fi
exit "$failed"
