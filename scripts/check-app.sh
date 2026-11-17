#!/usr/bin/env bash
# Check a built BusySign.app: --version prints VERSION, the binary's minos is 15.0, codesign --verify passes.
# Usage: scripts/check-app.sh <path/BusySign.app>   (VERSION is read from BUSYSIGN_ROOT, default the repo root)
set -euo pipefail

usage() {
    echo "usage: $0 <path/BusySign.app>" >&2
    exit 2
}

[[ $# -eq 1 && -n "$1" ]] || usage
app="${1%/}"
root="${BUSYSIGN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
bin="$app/Contents/MacOS/BusySign"
want_minos="15.0"

if [[ ! -f "$root/VERSION" ]]; then
    echo "error: $root/VERSION not found" >&2
    exit 1
fi
want_version="$(tr -d '[:space:]' < "$root/VERSION")"
if [[ ! -f "$bin" || ! -x "$bin" ]]; then
    echo "error: $bin not found or not executable" >&2
    exit 1
fi

failed=0
report() {
    echo "error: $*" >&2
    failed=$((failed + 1))
}

# The one run of the app binary: --version prints the version and exits before any app code starts.
rc=0
got_version="$("$bin" --version < /dev/null)" || rc=$?
if [[ $rc -ne 0 ]]; then
    report "version: $bin --version exited with $rc"
elif [[ "$got_version" != "$want_version" ]]; then
    report "version: --version printed '$got_version', VERSION is $want_version"
else
    echo "version ok: $got_version"
fi

if ! build_info="$(vtool -show-build "$bin" 2>&1)"; then
    report "minos: vtool -show-build failed: $(printf '%s' "$build_info" | tr '\n' ' ')"
else
    minos_values="$(printf '%s\n' "$build_info" | awk '$1 == "minos" { print $2 }')"
    wrong=""
    while IFS= read -r minos; do
        [[ -z "$minos" || "$minos" == "$want_minos" ]] || wrong="$wrong $minos"
    done <<< "$minos_values"
    if [[ -z "$minos_values" ]]; then
        report "minos: vtool -show-build shows no minos for $bin"
    elif [[ -n "$wrong" ]]; then
        report "minos:$wrong, want $want_minos"
    else
        echo "minos ok: $want_minos"
    fi
fi

if ! codesign_out="$(codesign --verify "$app" 2>&1)"; then
    report "codesign: codesign --verify failed: $(printf '%s' "$codesign_out" | tr '\n' ' ')"
else
    echo "codesign ok"
fi

if [[ $failed -gt 0 ]]; then
    echo "error: $app failed $failed of 3 checks" >&2
    exit 1
fi
echo "app ok: $app"
