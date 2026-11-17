#!/usr/bin/env bash
# Tests for scripts/ci-ok.sh over the job results GitHub can report (success, failure, cancelled, skipped).
# Usage: scripts/tests/test-ci-ok.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/ci-ok.sh"

# results <want-rc> <scripts> <authors> <macos> [failing leg...]: exit code, and an ::error:: line for each failing
# leg and none for the others.
results() {
    local want="$1" s="$2" a="$3" m="$4"
    shift 4
    begin "ci-ok scripts=$s authors=${a:-<empty>} macos=$m exits $want"
    run_in "$tmp_root" "$script" "$s" "$a" "$m"
    expect "exit $rc, want $want ($out $err)" [ "$rc" -eq "$want" ]
    local leg
    for leg in scripts authors macos; do
        case " $* " in
            *" $leg "*) expect "no ::error:: line for $leg ($out)" contains "$out" "::error::$leg: " ;;
            *) expect "an ::error:: line for $leg, which passed ($out)" lacks "$out" "::error::$leg" ;;
        esac
    done
    end
}

results 0 success success success
results 0 success skipped success
results 1 success failure success authors
results 1 success cancelled success authors
results 1 success "" success authors
results 1 failure skipped success scripts
results 1 skipped success success scripts
results 1 cancelled success success scripts
results 1 success success failure macos
results 1 success skipped skipped macos
results 1 success success cancelled macos
results 1 failure failure failure scripts authors macos
results 1 Success success success scripts

begin "ci-ok with two arguments exits 2"
run_in "$tmp_root" "$script" success success
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
end

finish
