#!/usr/bin/env bash
# Print the macOS SDK to build against: <sdk-path>, or an older SDK when it needs a SwiftUI macro plugin that's missing.
# Usage: scripts/pick-sdk.sh <developer-dir> <sdk-path>   (exit 1 when <developer-dir>/SDKs has no SDK that works)
set -euo pipefail

usage() {
    echo "usage: $0 <developer-dir> <sdk-path>" >&2
    exit 2
}

[[ $# -eq 2 && -n "$1" && -n "$2" && "$1" != -* && "$2" != -* ]] || usage
dev="$1"
sdk="$2"
[[ "$dev" == / ]] || dev="${dev%/}"
# DEVELOPER_DIR may name Xcode.app itself; xcrun then uses its Contents/Developer.
if [[ -d "$dev/Contents/Developer" ]]; then
    dev="$dev/Contents/Developer"
fi

# needs_plugin <sdk>: the SDK's SwiftUICore declares State as a macro implemented in the SwiftUIMacros compiler plugin
# (the 27 SDKs). Older SDKs declare other SwiftUIMacros macros too (Entry, Animatable), which BusySign does not use,
# so only State counts.
needs_plugin() {
    local framework="$1/System/Library/Frameworks/SwiftUICore.framework"
    [[ -d "$framework" ]] || return 1
    grep -rqsF --include='*.swiftinterface' 'module: "SwiftUIMacros", type: "StateMacro"' "$framework"
}

# has_plugin: libSwiftUIMacros.dylib is where the compiler of <developer-dir> loads plugins from: the toolchain
# (Command Line Tools: usr/ itself; Xcode: the default toolchain) and, for Xcode, the macOS platform.
has_plugin() {
    local dir
    for dir in \
        "$dev/usr/lib/swift/host/plugins" \
        "$dev/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins" \
        "$dev/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins"; do
        if [[ -f "$dir/libSwiftUIMacros.dylib" ]]; then
            return 0
        fi
    done
    return 1
}

if ! needs_plugin "$sdk" || has_plugin; then
    echo "$sdk"
    exit 0
fi

# The newest real MacOSX<major>.<minor>.sdk directory (symlinks such as MacOSX.sdk are skipped) without the State macro.
sdk_re='^MacOSX([0-9]+)\.([0-9]+)\.sdk$'
best=""
best_major=-1
best_minor=-1
for candidate in "$dev"/SDKs/MacOSX*.sdk; do
    [[ -d "$candidate" && ! -L "$candidate" ]] || continue
    name="$(basename "$candidate")"
    [[ "$name" =~ $sdk_re ]] || continue
    major=$((10#${BASH_REMATCH[1]}))
    minor=$((10#${BASH_REMATCH[2]}))
    if needs_plugin "$candidate"; then
        continue
    fi
    if [[ $major -gt $best_major || ( $major -eq $best_major && $minor -gt $best_minor ) ]]; then
        best="$candidate"
        best_major=$major
        best_minor=$minor
    fi
done

if [[ -z "$best" ]]; then
    echo "error: $sdk needs the SwiftUI macro plugin, which $dev lacks, and $dev/SDKs has no SDK without it:" \
        "building needs Xcode, or Command Line Tools that include the SwiftUI macro plugin" >&2
    exit 1
fi
echo "$best"
