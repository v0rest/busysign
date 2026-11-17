#!/usr/bin/env bash
# Print code=false when a CI event changes only docs (*.md, docs/ images), else code=true; any doubt gives code=true.
# Usage: scripts/changed-code.sh <event> <ref> <sha> <before> <after>   (sha: GITHUB_SHA, a PR's merge commit)
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "usage: $0 <event> <ref> <sha> <before> <after>" >&2
    exit 2
fi
event="$1"
ref="$2"
sha="$3"
before="$4"
after="$5"
sha_re='^[0-9a-f]{40}([0-9a-f]{24})?$'
zero_re='^0+$'

# decide <true|false> <reason>: the one line on stdout, the reason on stderr, and done.
decide() {
    echo "code=$1: $2" >&2
    echo "code=$1"
    exit 0
}

# is_sha <value>: a full lower-case hex sha that is not all zeros.
is_sha() {
    [[ "$1" =~ $sha_re && ! "$1" =~ $zero_re ]]
}

# plain_mode <mode>: a regular file, or no file (000000) on the side where it is added or deleted.
plain_mode() {
    [[ "$1" == 100644 || "$1" == 100755 || "$1" == 000000 ]]
}

case "$event" in
    pull_request)
        # GitHub checks out the merge of the PR into its base; its first parent is that base, so the diff is what
        # merging the PR changes, whatever the event's base sha says.
        if ! is_sha "$sha"; then
            decide true "pull_request without a usable merge commit sha"
        fi
        if ! git rev-parse --verify --quiet "$sha^2^{commit}" > /dev/null; then
            decide true "$sha is not a merge commit git has"
        fi
        diff_args=("$sha^1" "$sha")
        ;;
    push)
        case "$ref" in
            refs/heads/*) ;;
            *) decide true "push of $ref (release.yml's call for a tag runs everything)" ;;
        esac
        if [[ "$before" =~ $zero_re ]]; then
            decide true "first push of $ref, nothing to compare with"
        fi
        if ! is_sha "$before" || ! is_sha "$after"; then
            decide true "push without a usable before and after sha"
        fi
        diff_args=("$before" "$after")
        ;;
    *)
        decide true "event $event"
        ;;
esac

list="$(mktemp)"
trap 'rm -f "$list"' EXIT
# --raw for the file modes (a symlink is 120000), --no-renames so a file moved into docs/ is listed under its old
# path as well and a removed source counts as code.
if ! git diff --raw -z --no-renames "${diff_args[@]}" -- > "$list"; then
    decide true "git diff ${diff_args[*]} failed"
fi

count=0
code_files=0
# Each entry is ":<old mode> <new mode> <old sha> <new sha> <status>" NUL "<path>" NUL.
while IFS= read -r -d '' header && IFS= read -r -d '' path; do
    count=$((count + 1))
    modes="${header#:}"
    old_mode="${modes%% *}"
    modes="${modes#* }"
    new_mode="${modes%% *}"
    kind=code
    # Only a regular file (or none, on the side where it is added or deleted) can be docs: a symlink (120000) or a
    # submodule (160000) on either side can point a build input at a docs path.
    if plain_mode "$old_mode" && plain_mode "$new_mode"; then
        case "$path" in
            *.md | docs/*.png | docs/*.jpg | docs/*.jpeg | docs/*.gif | docs/*.svg | docs/*.webp) kind=docs ;;
        esac
    fi
    echo "$kind: $path ($old_mode -> $new_mode)" >&2
    if [[ "$kind" == code ]]; then
        code_files=$((code_files + 1))
    fi
done < "$list"

if [[ $count -eq 0 ]]; then
    decide true "no changed files in ${diff_args[*]}"
fi
if [[ $code_files -gt 0 ]]; then
    decide true "$code_files of $count changed file(s) are code"
fi
decide false "all $count changed file(s) are docs"
