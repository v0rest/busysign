#!/usr/bin/env bash
# Print the commit range check-authors.sh reads for a CI event: PR base..head, push before..after (first push: after).
# Usage: scripts/authors-range.sh <pull_request|push> <before> <after> <base-sha> <head-sha>   (unused ones may be "")
set -euo pipefail

usage() {
    echo "usage: $0 <pull_request|push> <before> <after> <base-sha> <head-sha>" >&2
    exit 2
}

[[ $# -eq 5 ]] || usage
event="$1"
before="$2"
after="$3"
base="$4"
head="$5"
sha_re='^[0-9a-f]{40}([0-9a-f]{24})?$'
zero_re='^0+$'

# need_sha <what> <value>: a full lower-case hex sha (SHA-1 or SHA-256), not all zeros unless <what> is "before".
need_sha() {
    if [[ ! "$2" =~ $sha_re ]]; then
        echo "error: $1 '$2' is not a full commit sha" >&2
        exit 2
    fi
    if [[ "$1" != before && "$2" =~ $zero_re ]]; then
        echo "error: $1 is all zeros" >&2
        exit 2
    fi
}

case "$event" in
    pull_request)
        need_sha base "$base"
        need_sha head "$head"
        echo "$base..$head"
        ;;
    push)
        need_sha before "$before"
        need_sha after "$after"
        if [[ "$before" =~ $zero_re ]]; then
            # The first push of the branch: every commit it brings, which is the pushed commit's whole history.
            echo "$after"
        else
            echo "$before..$after"
        fi
        ;;
    *)
        echo "error: event '$event' is neither pull_request nor push" >&2
        exit 2
        ;;
esac
