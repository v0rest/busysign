#!/usr/bin/env bash
# Tests for scripts/set-version.sh on a temp copy of VERSION and Version.swift.
# Usage: scripts/tests/test-set-version.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/set-version.sh"
swift_rel="Sources/BusySignCore/Version.swift"

# fresh_root <dir>: a copy of the repository's VERSION and Version.swift, plus pristine snapshots of both.
fresh_root() {
    mkdir -p "$1/$(dirname "$swift_rel")"
    cp "$repo_root/VERSION" "$1/VERSION"
    cp "$repo_root/$swift_rel" "$1/$swift_rel"
    cp "$1/VERSION" "$1/VERSION.orig"
    cp "$1/$swift_rel" "$1/Version.swift.orig"
}

# unchanged <dir>: VERSION and Version.swift equal their snapshots.
# shellcheck disable=SC2329  # called through expect
unchanged() {
    cmp -s "$1/VERSION" "$1/VERSION.orig" && cmp -s "$1/$swift_rel" "$1/Version.swift.orig"
}

root="$tmp_root/ok"
fresh_root "$root"
printf '1.2.3\n' > "$tmp_root/want-version"
sed 's/static let current = "[^"]*"/static let current = "1.2.3"/' "$root/Version.swift.orig" > "$tmp_root/want-swift"
begin "set-version 1.2.3 updates VERSION and Version.current"
run_in "$root" env BUSYSIGN_ROOT="$root" "$script" 1.2.3
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "VERSION is '$(cat "$root/VERSION")', want '1.2.3' and a newline" cmp -s "$root/VERSION" "$tmp_root/want-version"
expect "Version.swift differs from the original with only the current line changed" \
    cmp -s "$root/$swift_rel" "$tmp_root/want-swift"
expect "Version.swift has no 'static let current = \"1.2.3\"'" grep -q 'static let current = "1.2.3"' "$root/$swift_rel"
end

n=0
for bad in 1.2 v1.2.3 1.2.3.4 "1.2.3 " ""; do
    n=$((n + 1))
    root="$tmp_root/bad-$n"
    fresh_root "$root"
    begin "set-version '$bad' exits 2 and changes nothing"
    run_in "$root" env BUSYSIGN_ROOT="$root" "$script" "$bad"
    expect "exit $rc, want 2 ($err)" [ "$rc" -eq 2 ]
    expect "VERSION or Version.swift changed" unchanged "$root"
    end
done

root="$tmp_root/no-args"
fresh_root "$root"
begin "set-version without arguments exits 2"
run_in "$root" env BUSYSIGN_ROOT="$root" "$script"
expect "exit $rc, want 2 ($err)" [ "$rc" -eq 2 ]
expect "VERSION or Version.swift changed" unchanged "$root"
end

root="$tmp_root/no-line"
fresh_root "$root"
grep -v 'static let current' "$root/Version.swift.orig" > "$root/$swift_rel"
cp "$root/$swift_rel" "$root/Version.swift.orig"
begin "set-version fails and leaves VERSION alone when Version.swift has no current line"
run_in "$root" env BUSYSIGN_ROOT="$root" "$script" 1.2.3
expect "exit $rc, want 1 ($err)" [ "$rc" -eq 1 ]
expect "no reason naming Version.swift ($err)" contains "$err" "Version.swift"
expect "VERSION or Version.swift changed" unchanged "$root"
end

finish
