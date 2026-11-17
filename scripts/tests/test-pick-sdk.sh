#!/usr/bin/env bash
# Tests for scripts/pick-sdk.sh on fake developer directories (Command Line Tools and Xcode layouts).
# Usage: scripts/tests/test-pick-sdk.sh
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

script="$scripts_dir/pick-sdk.sh"
no_usable="needs Xcode, or Command Line Tools that include the SwiftUI macro plugin"

# make_sdk <sdks-dir> <name> macro|plain: a fake SDK whose SwiftUICore declares State as a SwiftUIMacros macro (macro,
# like the 27.2 SDK) or as a property wrapper (plain, like the 26.5 SDK). Both declare other SwiftUIMacros macros
# (Entry, Animatable) as the real ones do. Laid out like a real framework (Versions/A, Current and Modules symlinks).
make_sdk() {
    local framework="$1/$2/System/Library/Frameworks/SwiftUICore.framework"
    local module="$framework/Versions/A/Modules/SwiftUICore.swiftmodule"
    mkdir -p "$module"
    ln -s A "$framework/Versions/Current"
    ln -s Versions/Current/Modules "$framework/Modules"
    local arch file
    for arch in arm64e-apple-macos x86_64-apple-macos; do
        file="$module/$arch.swiftinterface"
        printf '%s\n' \
            '@attached(accessor) public macro Entry() = #externalMacro(module: "SwiftUIMacros", type: "EntryMacro")' \
            '@attached(member) public macro Animatable() = #externalMacro(module: "SwiftUIMacros",' \
            '    type: "AnimatableValuesMacro")' > "$file"
        if [[ "$3" == macro ]]; then
            printf '%s\n' '@attached(accessor) public macro State() =' \
                '#externalMacro(module: "SwiftUIMacros", type: "StateMacro")' >> "$file"
        else
            printf '%s\n' '@frozen @propertyWrapper public struct State<Value> : DynamicProperty {}' >> "$file"
        fi
    done
}

# make_plugin <dir>: libSwiftUIMacros.dylib in <dir>.
make_plugin() {
    mkdir -p "$1"
    : > "$1/libSwiftUIMacros.dylib"
}

# clt <dir>: a Command Line Tools tree without the SwiftUI macro plugin; MacOSX.sdk -> MacOSX27.2.sdk (macro),
# MacOSX26.5.sdk (plain), MacOSX26.sdk -> MacOSX26.5.sdk, as Command Line Tools 27.2 ships them.
clt() {
    mkdir -p "$1/SDKs" "$1/usr/lib/swift/host/plugins"
    : > "$1/usr/lib/swift/host/plugins/libSwiftMacros.dylib"
    make_sdk "$1/SDKs" MacOSX27.2.sdk macro
    make_sdk "$1/SDKs" MacOSX26.5.sdk plain
    ln -s MacOSX27.2.sdk "$1/SDKs/MacOSX.sdk"
    ln -s MacOSX27.2.sdk "$1/SDKs/MacOSX27.sdk"
    ln -s MacOSX26.5.sdk "$1/SDKs/MacOSX26.sdk"
}

# xcode <dir.app>: an Xcode tree with a macro SDK; the plugin is added by the test.
xcode() {
    local dev="$1/Contents/Developer"
    local sdks="$dev/Platforms/MacOSX.platform/Developer/SDKs"
    mkdir -p "$sdks" "$dev/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"
    make_sdk "$sdks" MacOSX27.2.sdk macro
    ln -s MacOSX27.2.sdk "$sdks/MacOSX.sdk"
}

xcode_platform_plugins="Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"
xcode_toolchain_plugins="Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"
xcode_sdk="Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

dev="$tmp_root/clt-plugin"
clt "$dev"
make_plugin "$dev/usr/lib/swift/host/plugins"
begin "Command Line Tools with the plugin keep the macro SDK"
run_in "$tmp_root" "$script" "$dev" "$dev/SDKs/MacOSX.sdk"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "printed '$out', want the SDK unchanged" [ "$out" == "$dev/SDKs/MacOSX.sdk" ]
end

app="$tmp_root/xcode-platform/Xcode.app"
xcode "$app"
make_plugin "$app/$xcode_platform_plugins"
begin "Xcode with the plugin in the macOS platform keeps the macro SDK"
run_in "$tmp_root" "$script" "$app/Contents/Developer" "$app/$xcode_sdk"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "printed '$out', want the SDK unchanged" [ "$out" == "$app/$xcode_sdk" ]
end

begin "Xcode given as the .app path (DEVELOPER_DIR=/Applications/Xcode.app) keeps the macro SDK"
run_in "$tmp_root" "$script" "$app" "$app/$xcode_sdk"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "printed '$out', want the SDK unchanged" [ "$out" == "$app/$xcode_sdk" ]
end

app="$tmp_root/xcode-toolchain/Xcode.app"
xcode "$app"
make_plugin "$app/$xcode_toolchain_plugins"
begin "Xcode with the plugin in the default toolchain keeps the macro SDK"
run_in "$tmp_root" "$script" "$app/Contents/Developer" "$app/$xcode_sdk"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "printed '$out', want the SDK unchanged" [ "$out" == "$app/$xcode_sdk" ]
end

dev="$tmp_root/clt-old-sdk"
clt "$dev"
begin "Command Line Tools without the plugin fall back to the newest SDK without the macro"
run_in "$tmp_root" "$script" "$dev" "$dev/SDKs/MacOSX.sdk"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "printed '$out', want $dev/SDKs/MacOSX26.5.sdk" [ "$out" == "$dev/SDKs/MacOSX26.5.sdk" ]
end

begin "a developer dir given with a trailing slash prints the same fallback path"
run_in "$tmp_root" "$script" "$dev/" "$dev/SDKs/MacOSX.sdk"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "printed '$out', want $dev/SDKs/MacOSX26.5.sdk" [ "$out" == "$dev/SDKs/MacOSX26.5.sdk" ]
end

begin "an SDK with only other SwiftUIMacros macros (Entry, Animatable) is kept although the plugin is missing"
run_in "$tmp_root" "$script" "$dev" "$dev/SDKs/MacOSX26.sdk"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "printed '$out', want the SDK unchanged" [ "$out" == "$dev/SDKs/MacOSX26.sdk" ]
end

dev="$tmp_root/clt-no-usable"
mkdir -p "$dev/SDKs"
make_sdk "$dev/SDKs" MacOSX27.2.sdk macro
make_sdk "$dev/SDKs" MacOSX27.1.sdk macro
make_sdk "$dev/SDKs" MacOSX99.sdk plain
make_sdk "$dev/SDKs" MacOSX26.5.1.sdk plain
make_sdk "$tmp_root/elsewhere" MacOSX26.5.sdk plain
ln -s "$tmp_root/elsewhere/MacOSX26.5.sdk" "$dev/SDKs/MacOSX26.9.sdk"
ln -s MacOSX27.2.sdk "$dev/SDKs/MacOSX.sdk"
begin "no plugin and no usable SDK (only macro SDKs, odd names and a symlink) exits 1 with one line"
run_in "$tmp_root" "$script" "$dev" "$dev/SDKs/MacOSX.sdk"
expect "exit $rc, want 1" [ "$rc" -eq 1 ]
expect "printed '$out' on stdout, want nothing" [ -z "$out" ]
expect "reason '$err' lacks '$no_usable'" contains "$err" "$no_usable"
expect "reason has $(line_count "$err") lines, want 1" [ "$(line_count "$err")" -eq 1 ]
end

dev="$tmp_root/clt-order"
mkdir -p "$dev/SDKs"
make_sdk "$dev/SDKs" MacOSX27.2.sdk macro
make_sdk "$dev/SDKs" MacOSX9.9.sdk plain
make_sdk "$dev/SDKs" MacOSX26.5.sdk plain
make_sdk "$dev/SDKs" MacOSX26.10.sdk plain
make_sdk "$dev/SDKs" MacOSX26.9.sdk plain
ln -s MacOSX27.2.sdk "$dev/SDKs/MacOSX.sdk"
begin "versions compare numerically: 26.10 is newer than 26.9, 26.5 and 9.9"
run_in "$tmp_root" "$script" "$dev" "$dev/SDKs/MacOSX.sdk"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "printed '$out', want $dev/SDKs/MacOSX26.10.sdk" [ "$out" == "$dev/SDKs/MacOSX26.10.sdk" ]
end

dev="$tmp_root/clt-minor"
mkdir -p "$dev/SDKs"
make_sdk "$dev/SDKs" MacOSX27.2.sdk macro
make_sdk "$dev/SDKs" MacOSX26.4.sdk plain
make_sdk "$dev/SDKs" MacOSX26.5.sdk plain
ln -s MacOSX27.2.sdk "$dev/SDKs/MacOSX.sdk"
begin "the minor version decides within one major: 26.5 over 26.4"
run_in "$tmp_root" "$script" "$dev" "$dev/SDKs/MacOSX.sdk"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "printed '$out', want $dev/SDKs/MacOSX26.5.sdk" [ "$out" == "$dev/SDKs/MacOSX26.5.sdk" ]
end

dev="$tmp_root/clt-symlink"
mkdir -p "$dev/SDKs"
make_sdk "$dev/SDKs" MacOSX27.2.sdk macro
make_sdk "$dev/SDKs" MacOSX26.5.sdk plain
make_sdk "$tmp_root/elsewhere-2" MacOSX26.5.sdk plain
ln -s "$tmp_root/elsewhere-2/MacOSX26.5.sdk" "$dev/SDKs/MacOSX26.9.sdk"
ln -s MacOSX27.2.sdk "$dev/SDKs/MacOSX.sdk"
begin "a symlinked SDK is ignored even when its name is newer"
run_in "$tmp_root" "$script" "$dev" "$dev/SDKs/MacOSX.sdk"
expect "exit $rc, want 0 ($err)" [ "$rc" -eq 0 ]
expect "printed '$out', want $dev/SDKs/MacOSX26.5.sdk" [ "$out" == "$dev/SDKs/MacOSX26.5.sdk" ]
end

begin "pick-sdk with one argument exits 2"
run_in "$tmp_root" "$script" "$dev"
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
end

begin "pick-sdk without arguments exits 2"
run_in "$tmp_root" "$script"
expect "exit $rc, want 2" [ "$rc" -eq 2 ]
end

finish
