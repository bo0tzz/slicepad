#!/usr/bin/env bash
# Package the engine as an XCFramework the Xcode project can link.
#
# libslic3r pulls in a few dozen static archives between its own targets and the
# dependency prefix, and an Xcode target listing them all would go stale on every
# engine bump. Merging them into one archive keeps the app project's link line to a
# single entry; overlinking costs nothing because the final link dead-strips.
#
# Device only. Sideloading targets a real iPad, and a simulator slice would mean
# building the whole dependency set a second time.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build="$root/build/ios"
stage="$root/build/ios-framework"
prefix="$root/build/deps-prefix/usr/local"

if [[ ! -d "$prefix" ]]; then
    echo "No iOS dependency prefix at $prefix — run 'mise run deps' for iOS first." >&2
    exit 1
fi

cmake -S "$root" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_PREFIX_PATH="$prefix"
cmake --build "$build" --target slicepad_core --parallel "${NPROC:-4}"

rm -rf "$stage"
mkdir -p "$stage/Headers"

# Every archive the build produced, plus every one it linked against.
mapfile -t archives < <(find "$build" "$prefix/lib" -name '*.a' | sort -u)
echo "Merging ${#archives[@]} archives"
libtool -static -o "$stage/libslicepad.a" "${archives[@]}" 2>/dev/null

cp "$root/core/include/slicepad.h" "$stage/Headers/"
cat > "$stage/Headers/module.modulemap" <<'MAP'
module SlicePadCore {
    header "slicepad.h"
    export *
}
MAP

rm -rf "$root/build/SlicePadCore.xcframework"
xcodebuild -create-xcframework \
    -library "$stage/libslicepad.a" -headers "$stage/Headers" \
    -output "$root/build/SlicePadCore.xcframework"

echo "Wrote build/SlicePadCore.xcframework"
