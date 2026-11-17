#!/usr/bin/env bash
# Tests for scripts/authors-range.sh: the commit range the authors check reads for each event.
# Usage: scripts/tests/test-authors-range.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/authors-range.sh"
a=1111111111111111111111111111111111111111
b=2222222222222222222222222222222222222222
c=abcdef0123456789abcdef0123456789abcdef01
zero=0000000000000000000000000000000000000000

# range_is <name> <want> <args...>: the script exits 0 and prints exactly <want>.
range_is() {
    local name="$1" want="$2"
    shift 2
    begin "$name"
    run_in "$tmp_root" "$script" "$@"
    expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
    expect "printed '$out', want '$want'" [ "$out" == "$want" ]
    end
}

# usage_error <name> <args...>: the script exits 2 and prints nothing on stdout.
usage_error() {
    local name="$1"
    shift
    begin "$name"
    run_in "$tmp_root" "$script" "$@"
    expect "exit $rc, want 2 ($out)" [ "$rc" -eq 2 ]
    expect "printed '$out' on stdout, want nothing" [ -z "$out" ]
    end
}

range_is "pull_request: base..head" "$a..$b" pull_request "" "" "$a" "$b"
range_is "pull_request ignores before and after" "$a..$b" pull_request "$c" "$c" "$a" "$b"
range_is "push: before..after" "$a..$b" push "$a" "$b" "" ""
range_is "push with an all-zero before (first push): after alone, its whole history" "$c" push "$zero" "$c" "" ""
range_is "a 64-character (SHA-256) sha is accepted" "${a}${a:0:24}..$b" push "${a}${a:0:24}" "$b" "" ""

usage_error "pull_request without a base sha exits 2" pull_request "" "" "" "$b"
usage_error "pull_request with a non-hex head exits 2" pull_request "" "" "$a" "HEAD"
usage_error "push with a short sha exits 2" push "abc1234" "$b" "" ""
usage_error "push with an empty after exits 2" push "$a" "" "" ""
usage_error "push with an option-like before exits 2" push "--all" "$b" "" ""
usage_error "push with an upper-case sha exits 2" push "ABCDEF0123456789ABCDEF0123456789ABCDEF01" "$b" "" ""
usage_error "an all-zero after exits 2" push "$a" "$zero" "" ""
usage_error "another event (workflow_dispatch) exits 2" workflow_dispatch "$a" "$b" "$a" "$b"
usage_error "four arguments exit 2" push "$a" "$b" ""
usage_error "no arguments exit 2"

finish
