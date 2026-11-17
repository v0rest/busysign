#!/usr/bin/env bash
# Run every scripts/tests/test-*.sh; exit 1 if any of them failed.
# Usage: scripts/tests/run-tests.sh
set -euo pipefail

tests_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

count=0
failed=""
for test in "$tests_dir"/test-*.sh; do
    [[ -e "$test" ]] || continue
    name="$(basename "$test")"
    count=$((count + 1))
    echo "== $name"
    if ! "$test"; then
        failed="$failed $name"
    fi
done

if [[ $count -eq 0 ]]; then
    echo "FAIL run-tests: no test-*.sh in $tests_dir"
    exit 1
fi
if [[ -n "$failed" ]]; then
    echo "FAIL run-tests: failed:$failed"
    exit 1
fi
echo "all $count test files passed"
