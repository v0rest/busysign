#!/usr/bin/env bash
# Tests for scripts/changed-code.sh: which changes are docs only (macOS legs skipped) and which events run everything.
# Usage: scripts/tests/test-changed-code.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/changed-code.sh"
zero=0000000000000000000000000000000000000000
main=refs/heads/main
pr_ref=refs/pull/1/merge

repo="$tmp_root/repo"
new_repo "$repo"
mkdir -p "$repo/Sources/App" "$repo/docs/images" "$repo/scripts" "$repo/.github/workflows"
echo "# BusySign" > "$repo/README.md"
echo "let a = 1" > "$repo/Sources/App/a.swift"
printf 'png' > "$repo/docs/images/x.png"
printf 'png' > "$repo/docs/a.png"
printf '# Guide\n\nHow to build it.\n' > "$repo/docs/guide.md"
echo "echo hi" > "$repo/scripts/s.sh"
echo "name: CI" > "$repo/.github/workflows/ci.yml"
commit_all "$repo" "base"
base="$(git -C "$repo" rev-parse HEAD)"

# change <name> <from> <command...>: a commit on a new branch off <from> made by <command> (run in the repo); prints
# its sha.
change() {
    local name="$1" from="$2"
    shift 2
    git -C "$repo" checkout -q -b "$name" "$from"
    (cd "$repo" && "$@")
    git -C "$repo" add -A
    git -C "$repo" commit -q --allow-empty -m "$name"
    git -C "$repo" rev-parse HEAD
}

# merge_ref <into> <head>: what GitHub checks out for a pull request, a merge commit with parents <into> and <head>.
merge_ref() {
    git -C "$repo" checkout -q --detach "$1"
    git -C "$repo" merge -q --no-ff --no-edit -m "Merge $2 into $1" "$2"
    git -C "$repo" rev-parse HEAD
}

# decides <name> <want true|false> <args...>: the script exits 0 and prints exactly code=<want>.
decides() {
    local name="$1" want="$2"
    shift 2
    begin "$name -> code=$want"
    run_in "$repo" "$script" "$@"
    expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
    expect "printed '$out', want 'code=$want' ($err)" [ "$out" == "code=$want" ]
    end
}

# pr <name> <want> <command...>: a pull request off base whose one commit is made by <command>, classified on the
# merge commit GitHub would check out.
n=0
pr() {
    local name="$1" want="$2" head
    shift 2
    n=$((n + 1))
    head="$(change "pr-$n" "$base" "$@")"
    decides "pull_request: $name" "$want" pull_request "$pr_ref" "$(merge_ref "$base" "$head")" "" ""
}

pr "only README.md" false sh -c 'echo more >> README.md'
pr "README.md and a Swift source" true sh -c 'echo more >> README.md; echo "let b = 2" >> Sources/App/a.swift'
pr "docs/images/x.png" false sh -c 'printf png2 > docs/images/x.png'
pr "docs/x.svg" false sh -c 'echo "<svg/>" > docs/x.svg'
# shellcheck disable=SC2016  # $e belongs to the sh -c script
pr "docs images in every allowed type" false \
    sh -c 'for e in md png jpg jpeg gif svg webp; do echo x > "docs/images/new.$e"; done'
pr "a docs image whose name has a space" false sh -c 'printf png > "docs/images/menu bar.png"'
pr "docs/a.swift (not a docs type)" true sh -c 'echo "let d = 4" > docs/a.swift'
pr "docs/build.sh (not a docs type)" true sh -c 'echo "echo x" > docs/build.sh'
pr "docs/X.PNG (the extension match is case-sensitive)" true sh -c 'printf png > docs/X.PNG'
pr "scripts/foo.md (any *.md is docs)" false sh -c 'echo notes > scripts/foo.md'
pr ".github/workflows/ci.yml" true sh -c 'echo "on: push" >> .github/workflows/ci.yml'
pr "an empty diff" true true
pr "a Swift source renamed to docs/a.md (the deletion counts)" true sh -c 'git mv Sources/App/a.swift docs/a.md'
pr "docs/guide.md renamed to Sources/App/guide.swift (the addition counts)" true \
    sh -c 'git mv docs/guide.md Sources/App/guide.swift'
pr "a deleted Swift source" true sh -c 'git rm -q Sources/App/a.swift'
pr "docsx/a.png (not under docs/)" true sh -c 'mkdir docsx && echo x > docsx/a.png'
pr "NOTES.MD (the match is case-sensitive)" true sh -c 'echo x > NOTES.MD'
pr "Sources/App/a.swift made a symlink to docs/a.swift" true \
    sh -c 'cp Sources/App/a.swift docs/a.swift && rm Sources/App/a.swift &&
        ln -s ../../docs/a.swift Sources/App/a.swift'
pr "a symlink added at a docs path (docs/images/link.png)" true \
    sh -c 'ln -s ../../Sources/App/a.swift docs/images/link.png'
pr "a symlink named like docs (notes.md)" true sh -c 'ln -s Sources/App/a.swift notes.md'

# Symlinks already on base: a later edit of the docs file one points to is a docs change (known limit; adding the
# symlink was the code change).
linked="$(change linked "$base" \
    sh -c 'ln -s ../../docs/a.png Sources/App/logo.png && ln -s ../../Sources/App/a.swift docs/images/link.png')"
head="$(change edit-linked "$linked" sh -c 'printf png2 > docs/a.png')"
decides "pull_request: a later edit of docs/a.png, which a symlink on base points to" false \
    pull_request "$pr_ref" "$(merge_ref "$linked" "$head")" "" ""
head="$(change unlink "$linked" sh -c 'rm docs/images/link.png && printf png > docs/images/link.png')"
decides "pull_request: the symlink docs/images/link.png replaced by a regular png (mode 120000 on the old side)" true \
    pull_request "$pr_ref" "$(merge_ref "$linked" "$head")" "" ""

# The merge commit decides, not the PR's own base: the branch merged main (a code change) and then reverted it, so the
# PR's commits since the old base cancel out to docs, but merging it into main reverts code.
main_code="$(change main-code "$base" sh -c 'echo "let c = 3" >> Sources/App/a.swift')"
change side "$base" sh -c 'echo more >> README.md' > /dev/null
git -C "$repo" merge -q --no-edit -m "Merge main" "$main_code"
git -C "$repo" revert --no-edit "$main_code" > /dev/null
reverted="$(git -C "$repo" rev-parse HEAD)"
expect_docs_only="$(git -C "$repo" diff --name-only "$base" "$reverted")"
begin "fixture: base..head of the merge-then-revert branch is README.md only"
expect "base..head lists '$expect_docs_only'" [ "$expect_docs_only" == "README.md" ]
end
decides "pull_request: branch merged main then reverted it (first-parent diff is code)" true \
    pull_request "$pr_ref" "$(merge_ref "$main_code" "$reverted")" "" ""

# Main moved on with code after a docs-only branch left it: the merge commit's first-parent diff is still docs only.
readme_head="$(git -C "$repo" rev-parse pr-1)"
decides "pull_request: main moved on with code, the PR itself only README.md" false \
    pull_request "$pr_ref" "$(merge_ref "$main_code" "$readme_head")" "" ""

decides "pull_request: a sha that is not a merge commit" true pull_request "$pr_ref" "$readme_head" "" ""
decides "pull_request: a sha git does not have" true \
    pull_request "$pr_ref" 1111111111111111111111111111111111111111 "" ""
decides "pull_request: an empty sha" true pull_request "$pr_ref" "" "" ""
decides "pull_request: a sha that is not hex" true pull_request "$pr_ref" HEAD "" ""

decides "push: before..after with only README.md" false push "$main" "$readme_head" "$base" "$readme_head"
code_head="$(git -C "$repo" rev-parse pr-2)"
decides "push: before..after with a Swift source" true push "$main" "$code_head" "$base" "$code_head"
decides "push: all-zero before (first push)" true push "$main" "$readme_head" "$zero" "$readme_head"
begin "push: all-zero before gives the first-push reason"
run_in "$repo" "$script" push "$main" "$readme_head" "$zero" "$readme_head"
expect "reason '$err' does not say first push" contains "$err" "first push"
end
decides "push of a tag (release.yml's call) with only README.md" true \
    push refs/tags/v1.2.3 "$readme_head" "$base" "$readme_head"
decides "push: a before git does not have" true \
    push "$main" "$readme_head" 1111111111111111111111111111111111111111 "$readme_head"
decides "push: a before that is not a sha" true push "$main" "$readme_head" HEAD "$readme_head"
decides "another event (workflow_dispatch)" true workflow_dispatch "$main" "$readme_head" "" ""

begin "changed-code with four arguments exits 2"
run_in "$repo" "$script" push "$main" "$readme_head" "$base"
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
expect "printed '$out' on stdout, want nothing" [ -z "$out" ]
end

finish
