#!/usr/bin/env bash
# Tests for scripts/check-release-assets.sh: the published release has exactly the tarball and its .sha256.
# Usage: scripts/tests/test-check-release-assets.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/check-release-assets.sh"
tar_name="busysign-1.2.3.tar.gz"
sha_name="busysign-1.2.3.tar.gz.sha256"

# assets <name> <want-rc> <version> <stdin text>
assets() {
    begin "$1"
    printf '%s' "$4" > "$tmp_root/names"
    rc=0
    out="$("$script" "$3" < "$tmp_root/names" 2> "$tmp_root/.stderr")" || rc=$?
    err="$(cat "$tmp_root/.stderr")"
    expect "exit $rc, want $2 ($out $err)" [ "$rc" -eq "$2" ]
}

assets "the tarball and its .sha256 pass" 0 1.2.3 "$tar_name"$'\n'"$sha_name"$'\n'
expect "the names are not listed ($out)" contains "$out" "$tar_name"
end

assets "the two assets in the other order pass" 0 1.2.3 "$sha_name"$'\n'"$tar_name"$'\n'
end

assets "a missing .sha256 fails and names it" 1 1.2.3 "$tar_name"$'\n'
expect "reason '$err' does not name $sha_name" contains "$err" "$sha_name"
end

assets "a missing tarball fails and names it" 1 1.2.3 "$sha_name"$'\n'
expect "reason '$err' does not name $tar_name" contains "$err" "$tar_name"
end

assets "a third asset fails and names it" 1 1.2.3 "$tar_name"$'\n'"$sha_name"$'\n'"notes.txt"$'\n'
expect "reason '$err' does not name notes.txt" contains "$err" "notes.txt"
end

assets "assets of another version fail" 1 1.2.3 "busysign-1.2.4.tar.gz"$'\n'"busysign-1.2.4.tar.gz.sha256"$'\n'
end

assets "a name listed twice fails" 1 1.2.3 "$tar_name"$'\n'"$tar_name"$'\n'"$sha_name"$'\n'
end

assets "no assets fail" 1 1.2.3 ""
end

assets "the last name without a newline still counts" 0 1.2.3 "$tar_name"$'\n'"$sha_name"
end

assets "a version that is not X.Y.Z exits 2" 2 v1.2.3 "$tar_name"$'\n'"$sha_name"$'\n'
end

begin "check-release-assets without arguments exits 2"
run_in "$tmp_root" "$script"
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
end

finish
