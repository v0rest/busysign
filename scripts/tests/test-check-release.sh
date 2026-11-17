#!/usr/bin/env bash
# Tests for scripts/check-release.sh on a temp git repository with main, a side branch and release tags.
# Usage: scripts/tests/test-check-release.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/check-release.sh"
swift_rel="Sources/BusySignCore/Version.swift"

# version_files <dir> <VERSION> <Version.current>: writes VERSION and a Version.swift into <dir>.
version_files() {
    mkdir -p "$1/$(dirname "$swift_rel")"
    printf '%s\n' "$2" > "$1/VERSION"
    sed "s/static let current = \"[^\"]*\"/static let current = \"$3\"/" "$repo_root/$swift_rel" > "$1/$swift_rel"
}

repo="$tmp_root/repo"
new_repo "$repo"
version_files "$repo" 0.1.0 0.1.0
commit_all "$repo" "release 0.1.0"
git -C "$repo" tag -a -m "BusySign 0.1.0" v0.1.0
git -C "$repo" tag v9.9.9
git -C "$repo" switch -q -c side
commit_as "$repo" "$GIT_AUTHOR_EMAIL" "$GIT_COMMITTER_EMAIL" "side work"
git -C "$repo" switch -q main
commit_as "$repo" "$GIT_AUTHOR_EMAIL" "$GIT_COMMITTER_EMAIL" "main moves on"

begin "matching tag on main passes"
run_in "$repo" env BUSYSIGN_ROOT="$repo" "$script" v0.1.0 main
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
end

begin "v9.9.9 fails: tag does not match VERSION"
run_in "$repo" env BUSYSIGN_ROOT="$repo" "$script" v9.9.9 main
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "reason '$err' lacks 'tag v9.9.9 does not match VERSION'" contains "$err" "tag v9.9.9 does not match VERSION"
expect "reason is $(line_count "$err") lines, want 1" [ "$(line_count "$err")" -eq 1 ]
end

mismatch="$tmp_root/mismatch"
version_files "$mismatch" 0.1.0 0.2.0
begin "VERSION differing from Version.current fails"
run_in "$repo" env BUSYSIGN_ROOT="$mismatch" "$script" v0.1.0 main
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "reason '$err' lacks 'differs from Version.current'" contains "$err" "differs from Version.current"
expect "reason is $(line_count "$err") lines, want 1" [ "$(line_count "$err")" -eq 1 ]
end

malformed="$tmp_root/malformed"
version_files "$malformed" 0.1 0.1
begin "VERSION that is not X.Y.Z fails"
run_in "$repo" env BUSYSIGN_ROOT="$malformed" "$script" v0.1 main
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "reason '$err' lacks 'X.Y.Z'" contains "$err" "X.Y.Z"
end

missing="$tmp_root/missing-tag"
version_files "$missing" 0.3.0 0.3.0
begin "a tag that does not exist fails"
run_in "$repo" env BUSYSIGN_ROOT="$missing" "$script" v0.3.0 main
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "reason '$err' lacks 'tag v0.3.0 not found'" contains "$err" "tag v0.3.0 not found"
expect "reason is $(line_count "$err") lines, want 1" [ "$(line_count "$err")" -eq 1 ]
end

begin "a main ref that does not exist fails"
run_in "$repo" env BUSYSIGN_ROOT="$repo" "$script" v0.1.0 origin/main
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "reason '$err' lacks 'origin/main not found'" contains "$err" "origin/main not found"
expect "reason is $(line_count "$err") lines, want 1" [ "$(line_count "$err")" -eq 1 ]
end

git -C "$repo" tag -f v0.1.0 side >/dev/null
begin "matching tag on a side branch fails: not on main"
run_in "$repo" env BUSYSIGN_ROOT="$repo" "$script" v0.1.0 main
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "reason '$err' lacks 'not on main'" contains "$err" "not on main"
expect "reason is $(line_count "$err") lines, want 1" [ "$(line_count "$err")" -eq 1 ]
end

begin "wrong number of arguments exits 2"
run_in "$repo" env BUSYSIGN_ROOT="$repo" "$script" v0.1.0
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
end

finish
