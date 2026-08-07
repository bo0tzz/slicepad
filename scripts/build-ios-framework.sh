#!/usr/bin/env bash
# Package the engine as an XCFramework the Xcode project can link.
#
# libslic3r pulls in a few dozen static archives between its own targets and the
# dependency prefix, and an Xcode target listing them all would go stale on every
# engine bump. Merging them into one archive keeps the app project's link line to a
# single entry; overlinking costs nothing because the final link dead-strips.
#
# SLICEPAD_SDK picks the platform: iphoneos (default) or iphonesimulator. They
# are different Apple platforms rather than variants of one, so each needs its own
# dependency prefix and produces its own archive — an app built for the simulator
# cannot link the device slice.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdk="${SLICEPAD_SDK:-iphoneos}"
case "$sdk" in
    iphoneos)        build="$root/build/ios" ;;
    iphonesimulator) build="$root/build/iossim-fw" ;;
    *) echo "SLICEPAD_SDK must be iphoneos or iphonesimulator, not '$sdk'" >&2; exit 2 ;;
esac
stage="$root/build/ios-framework"
prefix="$root/build/deps-prefix/usr/local"

if [[ ! -d "$prefix" ]]; then
    echo "No dependency prefix at $prefix — run 'mise run deps' for $sdk first." >&2
    exit 1
fi

cmake -S "$root" -B "$build" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_SYSTEM_PROCESSOR=arm64 \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_PREFIX_PATH="$prefix" \
    -DCMAKE_FIND_ROOT_PATH="$prefix"
cmake --build "$build" --target slicepad_core --parallel "${NPROC:-4}"

rm -rf "$stage"
mkdir -p "$stage/Headers"

# Every archive the build produced, plus every one it linked against. Read in a
# loop rather than with mapfile, which macOS's bash 3.2 does not have.
archives=()
while IFS= read -r archive; do
    archives+=("$archive")
done < <(find "$build" "$prefix/lib" -name '*.a' | sort -u)
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
