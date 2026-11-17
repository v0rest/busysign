#!/usr/bin/env bash
# Helpers for scripts/tests/test-*.sh: a temp dir, an isolated git, and ok/FAIL reporting (sourced, not run).
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck disable=SC2034  # rc, out, err, repo_root and scripts_dir are read by the test files

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scripts_dir="$repo_root/scripts"

tmp_root="$(mktemp -d)"
trap 'rm -rf "$tmp_root"' EXIT

# Git in the tests sees neither the user's nor the system's configuration, nor a repository from the environment.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="Test Author" GIT_AUTHOR_EMAIL="1+tester@users.noreply.github.com"
export GIT_COMMITTER_NAME="Test Committer" GIT_COMMITTER_EMAIL="1+tester@users.noreply.github.com"
unset BUSYSIGN_ROOT

failures=0
case_name=""
case_errors=""

# begin <name>: starts a test case.
begin() {
    case_name="$1"
    case_errors=""
}

# expect <why> <command...>: records <why> as a failure of the current case unless the command succeeds.
expect() {
    local why="$1"
    shift
    "$@" || case_errors="${case_errors:+$case_errors; }$why"
}

# end: prints "ok <name>" or "FAIL <name>: <why>" for the current case.
end() {
    if [[ -z "$case_errors" ]]; then
        echo "ok $case_name"
    else
        echo "FAIL $case_name: $case_errors"
        failures=$((failures + 1))
    fi
}

# finish: exit status of the test file, 1 if any case failed.
finish() {
    [[ $failures -eq 0 ]] || exit 1
    exit 0
}

# contains <text> <needle>
contains() {
    [[ "$1" == *"$2"* ]]
}

# lacks <text> <needle>
lacks() {
    [[ "$1" != *"$2"* ]]
}

# line_count <text>: number of lines in <text> (0 when empty).
line_count() {
    if [[ -z "$1" ]]; then
        echo 0
    else
        printf '%s\n' "$1" | wc -l | tr -d ' '
    fi
}

# run_in <dir> <command...>: runs the command in <dir>; sets rc, out (stdout) and err (stderr).
run_in() {
    local dir="$1"
    shift
    rc=0
    out="$(cd "$dir" && "$@" 2>"$tmp_root/.stderr" </dev/null)" || rc=$?
    err="$(cat "$tmp_root/.stderr" 2>/dev/null || true)"
}

# new_repo <dir>: an empty git repository with branch main.
new_repo() {
    git init -q -b main "$1"
}

# commit_as <dir> <author-email> <committer-email> <message>: an empty commit with those e-mails.
commit_as() {
    GIT_AUTHOR_EMAIL="$2" GIT_COMMITTER_EMAIL="$3" git -C "$1" commit -q --allow-empty -m "$4"
}

# commit_all <dir> <message>: commits every change in <dir>.
commit_all() {
    git -C "$1" add -A
    git -C "$1" commit -q -m "$2"
}

# short_sha <dir> <rev>
short_sha() {
    git -C "$1" rev-parse --short "$2"
}
