#!/usr/bin/env bash
# Tests for scripts/make-release-tarball.sh on a temp git repository.
# Usage: scripts/tests/test-make-release-tarball.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/make-release-tarball.sh"
name="busysign-0.0.1.tar.gz"

repo="$tmp_root/repo"
new_repo "$repo"
mkdir -p "$repo/sub"
printf '0.0.1\n' > "$repo/VERSION"
printf 'nested\n' > "$repo/sub/file.txt"
commit_all "$repo" "release 0.0.1"
git -C "$repo" tag v0.0.1
# Changes after the tag must not reach the tarball.
printf '9.9.9\n' > "$repo/VERSION"
printf 'untracked\n' > "$repo/untracked.txt"

# only_prefixed <listing>: every path in the listing is under busysign-0.0.1/.
# shellcheck disable=SC2329  # called through expect
only_prefixed() {
    local path
    while IFS= read -r path; do
        [[ "$path" == busysign-0.0.1/* ]] || return 1
    done <<< "$1"
}

outdir="$tmp_root/out/nested"
begin "make-release-tarball writes the tarball and its .sha256 into a new outdir"
run_in "$repo" "$script" v0.0.1 0.0.1 "$outdir"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "stdout '$out' is not the two paths" [ "$out" = "$outdir/$name"$'\n'"$outdir/$name.sha256" ]
end

listing="$(tar -tzf "$outdir/$name" 2>&1 || true)"
begin "tarball lists only busysign-0.0.1/ paths, from the tagged commit"
expect "a path outside busysign-0.0.1/ ($listing)" only_prefixed "$listing"
expect "no busysign-0.0.1/VERSION ($listing)" grep -qx 'busysign-0.0.1/VERSION' <<< "$listing"
expect "no busysign-0.0.1/sub/file.txt ($listing)" grep -qx 'busysign-0.0.1/sub/file.txt' <<< "$listing"
expect "untracked file in the tarball" [ "$(grep -c untracked <<< "$listing" || true)" -eq 0 ]
mkdir -p "$tmp_root/extract"
tar -xzf "$outdir/$name" -C "$tmp_root/extract" 2>/dev/null || true
expect "VERSION in the tarball is not the tagged 0.0.1" \
    [ "$(cat "$tmp_root/extract/busysign-0.0.1/VERSION" 2>/dev/null)" = "0.0.1" ]
end

sha_line="$(cat "$outdir/$name.sha256" 2>/dev/null || true)"
begin ".sha256 is in shasum -a 256 format and passes shasum -c from the outdir"
expect "content '$sha_line' is not '<sha>  $name'" \
    grep -Eqx "[0-9a-f]{64}  busysign-0\\.0\\.1\\.tar\\.gz" "$outdir/$name.sha256"
expect ".sha256 has $(line_count "$sha_line") lines, want 1" [ "$(line_count "$sha_line")" -eq 1 ]
run_in "$outdir" shasum -a 256 -c "$name.sha256"
expect "shasum -c: exit $rc ($out $err)" [ "$rc" -eq 0 ]
end

for bad in 0.0 v0.0.1; do
    begin "make-release-tarball version '$bad' exits 2 and writes nothing"
    run_in "$repo" "$script" v0.0.1 "$bad" "$tmp_root/out-$bad"
    expect "exit $rc, want 2" [ "$rc" -eq 2 ]
    expect "outdir created" [ ! -e "$tmp_root/out-$bad" ]
    end
done

begin "a rev that is not a commit fails"
run_in "$repo" "$script" no-such-rev 0.0.1 "$tmp_root/out-norev"
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "reason '$err' lacks 'no-such-rev'" contains "$err" "no-such-rev"
expect "tarball written" [ ! -e "$tmp_root/out-norev/$name" ]
end

finish
