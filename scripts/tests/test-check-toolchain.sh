#!/usr/bin/env bash
# Tests for scripts/check-toolchain.sh with a stub xcrun on PATH (runs on Linux too).
# Usage: scripts/tests/test-check-toolchain.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/check-toolchain.sh"
clt=/Library/Developer/CommandLineTools

# A stub xcrun: `xcrun --find swift` prints $STUB_SWIFT and exits $STUB_RC.
mkdir -p "$tmp_root/bin"
cat > "$tmp_root/bin/xcrun" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "--find swift" ]] || { echo "stub xcrun: unexpected arguments: $*" >&2; exit 64; }
[[ -z "$STUB_SWIFT" ]] || echo "$STUB_SWIFT"
exit "$STUB_RC"
EOF
chmod +x "$tmp_root/bin/xcrun"

# toolchain <name> <want-rc> <stub path> <stub rc> <developer-dir>
toolchain() {
    begin "$1"
    run_in "$tmp_root" env PATH="$tmp_root/bin:$PATH" STUB_SWIFT="$3" STUB_RC="$4" "$script" "$5"
    expect "exit $rc, want $2 ($out $err)" [ "$rc" -eq "$2" ]
}

toolchain "swift from Command Line Tools passes" 0 "$clt/usr/bin/swift" 0 "$clt"
expect "the swift path is not printed ($out)" contains "$out" "$clt/usr/bin/swift"
end

toolchain "a developer dir with a trailing slash passes the same" 0 "$clt/usr/bin/swift" 0 "$clt/"
end

toolchain "swift from Xcode fails when Command Line Tools are wanted" 1 \
    "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" 0 "$clt"
expect "reason '$err' does not name the Xcode path" contains "$err" "/Applications/Xcode.app"
end

toolchain "a look-alike directory (CommandLineTools2) fails" 1 "${clt}2/usr/bin/swift" 0 "$clt"
end

toolchain "xcrun failing fails" 1 "" 1 "$clt"
end

toolchain "xcrun printing nothing fails" 1 "" 0 "$clt"
end

begin "check-toolchain without arguments exits 2"
run_in "$tmp_root" "$script"
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
end

finish
