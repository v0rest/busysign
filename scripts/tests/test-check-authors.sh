#!/usr/bin/env bash
# Tests for scripts/check-authors.sh on temp git repositories.
# Usage: scripts/tests/test-check-authors.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/check-authors.sh"
good="1+tester@users.noreply.github.com"
work="someone@example.com"
github="noreply@github.com"

repo="$tmp_root/good"
new_repo "$repo"
commit_as "$repo" "$good" "$good" one
commit_as "$repo" "$good" "$good" two
begin "noreply author and committer pass (whole history and A..B)"
run_in "$repo" "$script" HEAD
expect "HEAD: exit $rc, want 0 ($out $err)" [ "$rc" -eq 0 ]
expect "HEAD: no '2 commit' in the output ($out)" contains "$out" "2 commit"
run_in "$repo" "$script" HEAD~1..HEAD
expect "HEAD~1..HEAD: exit $rc, want 0 ($out $err)" [ "$rc" -eq 0 ]
expect "HEAD~1..HEAD: no '1 commit' in the output ($out)" contains "$out" "1 commit"
end

repo="$tmp_root/work-author"
new_repo "$repo"
commit_as "$repo" "$good" "$good" base
commit_as "$repo" "$work" "$good" "work e-mail"
want="$(short_sha "$repo" HEAD) author=$work committer=$good"
begin "author $work fails and names the commit"
run_in "$repo" "$script" HEAD~1..HEAD
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "output '$out' is not '$want'" [ "$out" = "$want" ]
end

repo="$tmp_root/work-committer"
new_repo "$repo"
commit_as "$repo" "$good" "$good" base
commit_as "$repo" "$good" "$work" "work committer"
want="$(short_sha "$repo" HEAD) author=$good committer=$work"
begin "committer $work fails and names the commit"
run_in "$repo" "$script" HEAD~1..HEAD
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "output '$out' is not '$want'" [ "$out" = "$want" ]
end

repo="$tmp_root/squash"
new_repo "$repo"
commit_as "$repo" "$good" "$good" base
commit_as "$repo" "$good" "$github" "squash merge (#1)"
begin "committer $github with a noreply author passes (squash merge)"
run_in "$repo" "$script" HEAD
expect "exit $rc, want 0 ($out $err)" [ "$rc" -eq 0 ]
end

repo="$tmp_root/github-author"
new_repo "$repo"
commit_as "$repo" "$good" "$good" base
commit_as "$repo" "$github" "$github" "web commit"
want="$(short_sha "$repo" HEAD) author=$github committer=$github"
begin "author $github fails"
run_in "$repo" "$script" HEAD
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "output '$out' is not '$want'" [ "$out" = "$want" ]
end

repo="$tmp_root/look-alike"
new_repo "$repo"
commit_as "$repo" "$good" "$good" base
commit_as "$repo" "x@users.noreply.github.com.example.com" "$good" "suffix"
commit_as "$repo" "x@noreply.github.com" "$good" "subdomain"
commit_as "$repo" "@users.noreply.github.com" "$good" "empty local part"
begin "look-alike noreply addresses fail"
run_in "$repo" "$script" HEAD~3..HEAD
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "$(line_count "$out") offending lines, want 3 ($out)" [ "$(line_count "$out")" -eq 3 ]
end

repo="$tmp_root/one-bad"
new_repo "$repo"
commit_as "$repo" "$work" "$work" "first push"
want="$(short_sha "$repo" HEAD) author=$work committer=$work"
begin "single rev on a one-commit history checks that commit"
run_in "$repo" "$script" HEAD
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "output '$out' is not '$want'" [ "$out" = "$want" ]
end

repo="$tmp_root/one-good"
new_repo "$repo"
commit_as "$repo" "$good" "$good" "first push"
begin "single rev on a one-commit noreply history passes"
run_in "$repo" "$script" HEAD
expect "exit $rc, want 0 ($out $err)" [ "$rc" -eq 0 ]
expect "no '1 commit' in the output ($out)" contains "$out" "1 commit"
end

repo="$tmp_root/bad-root"
new_repo "$repo"
commit_as "$repo" "$work" "$work" root
root_sha="$(git -C "$repo" rev-parse HEAD)"
commit_as "$repo" "$good" "$good" tip
want="$(short_sha "$repo" "$root_sha") author=$work committer=$work"
begin "single rev checks the whole history, A..B only the new commits"
run_in "$repo" "$script" HEAD
expect "HEAD: exit $rc, want 1" [ "$rc" -eq 1 ]
expect "HEAD: output '$out' is not '$want'" [ "$out" = "$want" ]
run_in "$repo" "$script" "$root_sha..HEAD"
expect "root..HEAD: exit $rc, want 0 ($out $err)" [ "$rc" -eq 0 ]
end

repo="$tmp_root/mailmap"
new_repo "$repo"
commit_as "$repo" "$good" "$good" base
commit_as "$repo" "$work" "$work" "work e-mail"
bad_sha="$(short_sha "$repo" HEAD)"
printf 'Someone <%s> <%s>\n' "$good" "$work" > "$repo/.mailmap"
git -C "$repo" add .mailmap
commit_as "$repo" "$good" "$good" "add mailmap"
want="$bad_sha author=$work committer=$work"
begin "a .mailmap does not hide a work e-mail"
run_in "$repo" "$script" HEAD
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "output '$out' is not '$want'" [ "$out" = "$want" ]
end

begin "a range git cannot read exits 2"
run_in "$repo" "$script" no-such-ref..HEAD
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
expect "no error message" [ -n "$err" ]
end

begin "no argument exits 2"
run_in "$repo" "$script"
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
end

finish
