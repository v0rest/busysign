#!/usr/bin/env bash
# Fail when a commit's author or committer e-mail is not a GitHub noreply address (committer noreply@github.com is ok).
# Usage: scripts/check-authors.sh <rev-range>   (A..B: the commits in B not in A; a single rev: its whole history)
set -euo pipefail

usage() {
    echo "usage: $0 <rev-range>" >&2
    exit 2
}

[[ $# -eq 1 && -n "$1" && "$1" != -* ]] || usage
range="$1"
suffix="@users.noreply.github.com"

# is_noreply <email>: a non-empty local part without '@', then @users.noreply.github.com.
is_noreply() {
    local local_part="${1%"$suffix"}"
    [[ "$1" == *"$suffix" && -n "$local_part" && "$local_part" != *@* ]]
}

# %ae and %ce are the e-mails as recorded; a .mailmap does not rewrite them. Fields are split on 0x1f so that an
# empty e-mail keeps its place.
if ! commits="$(git log --format='%h%x1f%ae%x1f%ce' "$range" --)"; then
    echo "error: cannot list the commits in $range" >&2
    exit 2
fi

total=0
bad=0
while IFS=$'\x1f' read -r sha author committer; do
    [[ -n "$sha" ]] || continue
    total=$((total + 1))
    if is_noreply "$author" && { is_noreply "$committer" || [[ "$committer" == "noreply@github.com" ]]; }; then
        continue
    fi
    echo "$sha author=$author committer=$committer"
    bad=$((bad + 1))
done <<< "$commits"

if [[ $bad -gt 0 ]]; then
    echo "error: $bad of $total commit(s) in $range: author and committer must end in $suffix" \
        "(committer noreply@github.com is accepted)" >&2
    exit 1
fi
echo "checked $total commit(s) in $range: every author and committer e-mail is allowed"
