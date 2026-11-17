#!/usr/bin/env bash
# Tests for scripts/check-app.sh on a BusySign.app built once by scripts/build-app.sh (macOS only).
# Usage: scripts/tests/test-check-app.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [[ "$(uname -s)" != Darwin ]]; then
    echo "skip check-app (not macOS)"
    finish
fi

script="$scripts_dir/check-app.sh"
app="$tmp_root/BusySign.app"

echo "building BusySign.app for the check-app tests (release build)"
if ! "$scripts_dir/build-app.sh" --output "$app" > "$tmp_root/build.log" 2>&1; then
    echo "FAIL check-app: scripts/build-app.sh failed:"
    tail -n 20 "$tmp_root/build.log"
    exit 1
fi

begin "check-app passes on the freshly built app"
run_in "$tmp_root" "$script" "$app"
expect "exit $rc, want 0 ($out $err)" [ "$rc" -eq 0 ]
end

other="$tmp_root/version-9.9.9"
mkdir -p "$other"
printf '9.9.9\n' > "$other/VERSION"
begin "check-app fails the version check when BUSYSIGN_ROOT has VERSION 9.9.9"
run_in "$tmp_root" env BUSYSIGN_ROOT="$other" "$script" "$app"
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "reason '$err' does not name the version check with 9.9.9" contains "$err" "error: version:"
expect "reason '$err' lacks 9.9.9" contains "$err" "9.9.9"
expect "minos reported as failed ($err)" lacks "$err" "error: minos"
expect "codesign reported as failed ($err)" lacks "$err" "error: codesign"
end

# A changed resource breaks the bundle signature; the executable stays untouched.
mkdir -p "$tmp_root/tampered"
tampered="$tmp_root/tampered/BusySign.app"
cp -R "$app" "$tampered"
printf 'x' >> "$tampered/Contents/Resources/AppIcon.icns"
begin "check-app fails the codesign check on an app with a changed resource"
run_in "$tmp_root" "$script" "$tampered"
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "reason '$err' does not name the codesign check" contains "$err" "error: codesign"
expect "version reported as failed ($err)" lacks "$err" "error: version"
expect "minos reported as failed ($err)" lacks "$err" "error: minos"
end

begin "check-app fails on a path without the BusySign binary"
run_in "$tmp_root" "$script" "$tmp_root/missing/BusySign.app"
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "reason '$err' lacks 'not found'" contains "$err" "not found"
end

begin "check-app without arguments exits 2"
run_in "$tmp_root" "$script"
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
end

finish
