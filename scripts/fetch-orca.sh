#!/usr/bin/env bash
# Fetch the pinned OrcaSlicer source into third_party/orcaslicer and apply our
# patch stack. The checkout is a build artifact: never edit it in place. To
# change engine behaviour, add a patch under patches/ (see patches/README.md).
set -euo pipefail

ORCA_REPO="https://github.com/OrcaSlicer/OrcaSlicer.git"
ORCA_TAG="v2.4.2"
ORCA_SHA="8500fcdccaa10b5099ac20d252af3a7c560046f1"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dest="$root/third_party/orcaslicer"
patches="$root/patches"

fetch() {
    rm -rf "$dest"
    mkdir -p "$dest"
    git -C "$dest" init -q
    git -C "$dest" remote add origin "$ORCA_REPO"
    # Fetch the pinned commit alone; the full history is ~5x the tree.
    git -C "$dest" fetch -q --depth 1 origin "$ORCA_SHA"
    git -C "$dest" -c advice.detachedHead=false checkout -q FETCH_HEAD
    git -C "$dest" tag "$ORCA_TAG"
}

apply_patches() {
    shopt -s nullglob
    local list=("$patches"/*.patch)
    if [ ${#list[@]} -eq 0 ]; then
        echo "No patches to apply."
        return
    fi
    for p in "${list[@]}"; do
        echo "  applying $(basename "$p")"
        git -C "$dest" apply --whitespace=nowarn "$p"
    done
    echo "Applied ${#list[@]} patch(es)."
}

# Identifies the pin plus the exact patch set, so editing a patch forces a clean
# re-apply instead of silently leaving a half-patched tree in place.
stamp_value() {
    shopt -s nullglob
    local list=("$patches"/*.patch)
    { echo "$ORCA_SHA"; [ ${#list[@]} -gt 0 ] && cat "${list[@]}"; } | sha256sum | cut -d' ' -f1
}

want="$(stamp_value)"
stamp="$dest/.slicepad-stamp"

if [ -d "$dest/.git" ]; then
    if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
        echo "OrcaSlicer $ORCA_TAG ($ORCA_SHA) + $(ls "$patches"/*.patch 2>/dev/null | wc -l) patch(es) already applied."
        exit 0
    fi
    echo "Pin or patch set changed; re-fetching from scratch."
fi

fetch
apply_patches
echo "$want" > "$stamp"
echo "OrcaSlicer $ORCA_TAG at $ORCA_SHA ready in $dest"
