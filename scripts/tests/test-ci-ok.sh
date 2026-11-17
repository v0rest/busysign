#!/usr/bin/env bash
# Tests for scripts/ci-ok.sh over the job results GitHub can report (success, failure, cancelled, skipped) and the
# changes job's code output.
# Usage: scripts/tests/test-ci-ok.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/ci-ok.sh"

# results <want-rc> <scripts> <authors> <macos> <changes> <code> [failing leg...]: exit code, and an ::error:: line for
# each failing leg and none for the others.
results() {
    local want="$1" s="$2" a="$3" m="$4" c="$5" code="$6"
    shift 6
    begin "ci-ok scripts=$s authors=${a:-<empty>} macos=$m changes=$c code=${code:-<empty>} exits $want"
    run_in "$tmp_root" "$script" "$s" "$a" "$m" "$c" "$code"
    expect "exit $rc, want $want ($out $err)" [ "$rc" -eq "$want" ]
    local leg
    for leg in scripts authors macos changes; do
        case " $* " in
            *" $leg "*) expect "no ::error:: line for $leg ($out)" contains "$out" "::error::$leg: " ;;
            *) expect "an ::error:: line for $leg, which passed ($out)" lacks "$out" "::error::$leg" ;;
        esac
    done
    end
}

# Code changed: every leg runs.
results 0 success success success success true
results 0 success skipped success success true
results 1 success failure success success true authors
results 1 success cancelled success success true authors
results 1 success "" success success true authors
results 1 failure skipped success success true scripts
results 1 skipped success success success true scripts
results 1 cancelled success success success true scripts
results 1 success success failure success true macos
results 1 success skipped skipped success true macos
results 1 success success cancelled success true macos
results 1 failure failure failure success true scripts authors macos
results 1 Success success success success true scripts

# Docs only: macos is skipped on purpose.
results 0 success success skipped success false
results 1 success success cancelled success false macos
results 1 success success failure success false macos
results 1 failure success skipped success false scripts
results 1 success failure skipped success false authors

# The changes job itself, or its output, is not as it should be.
results 1 success success skipped success "" macos
results 1 success success skipped success maybe macos
results 1 success success skipped failure "" macos changes
results 1 success success skipped cancelled "" macos changes
results 1 success success skipped skipped false macos changes
results 1 success success success failure true changes

begin "ci-ok with three arguments exits 2"
run_in "$tmp_root" "$script" success success success
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
end

finish
