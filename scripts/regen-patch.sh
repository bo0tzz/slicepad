#!/usr/bin/env bash
# Edit one patch in the stack, safely.
#
#   scripts/regen-patch.sh edit   patches/0012-forward-apple-platform.patch
#   ... change files under third_party/orcaslicer ...
#   scripts/regen-patch.sh finish patches/0012-forward-apple-platform.patch
#
# Two steps because a patch cannot be regenerated from the fully patched tree.
# `git -C checkout diff` returns the changes of every patch touching the file, so
# the result is a superset that no longer applies over its predecessors; diffing
# against the current file gives the opposite error, keeping only the new edit.
# And if a *later* patch touches the same file, its changes are indistinguishable
# from yours — which is why `edit` rewinds the tree to this patch rather than
# letting you work on top of the whole stack.
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: ${BASH_SOURCE[0]} edit|finish patches/NNNN-name.patch" >&2
    exit 2
fi

mode="$1"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
target="$root/$2"
[ -f "$target" ] || { echo "no such patch: $2" >&2; exit 1; }

checkout="$root/third_party/orcaslicer"
[ -d "$checkout/.git" ] || { echo "no engine checkout; run 'mise run fetch'" >&2; exit 1; }

state="$checkout/.slicepad-editing"

apply_upto() {  # apply every patch before $1, and $1 itself when $2 is "inclusive"
    git -C "$checkout" checkout -- .
    for p in "$root"/patches/*.patch; do
        if [ "$(basename "$p")" = "$(basename "$target")" ]; then
            [ "${2:-}" = "inclusive" ] && git -C "$checkout" apply "$p"
            return 0
        fi
        git -C "$checkout" apply "$p"
    done
}

apply_all() {
    git -C "$checkout" checkout -- .
    for p in "$root"/patches/*.patch; do git -C "$checkout" apply "$p"; done
}

files=$(grep '^diff --git' "$target" | sed 's|^diff --git a/||; s| b/.*$||' | sort -u)
[ -n "$files" ] || { echo "patch names no files" >&2; exit 1; }

case "$mode" in
edit)
    apply_upto "$target" inclusive
    basename "$target" > "$state"
    echo "Checkout is now at $(basename "$target"), without the patches after it."
    echo "Edit these files, then run: scripts/regen-patch.sh finish $2"
    printf '  %s\n' $files
    ;;

finish)
    if [ ! -f "$state" ] || [ "$(cat "$state")" != "$(basename "$target")" ]; then
        echo "run 'scripts/regen-patch.sh edit $2' first — the tree has to be" >&2
        echo "rewound to this patch, or later patches get folded into it." >&2
        exit 1
    fi

    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT

    for f in $files; do
        mkdir -p "$work/new/$(dirname "$f")"
        cp "$checkout/$f" "$work/new/$f"
    done

    apply_upto "$target"
    for f in $files; do
        mkdir -p "$work/base/$(dirname "$f")"
        if [ -f "$checkout/$f" ]; then cp "$checkout/$f" "$work/base/$f"; else : > "$work/base/$f"; fi
    done

    # The comment block explaining why the patch exists is written by hand, not
    # derived, so it survives regeneration.
    {
        sed -n '/^#/p' "$target"
        for f in $files; do
            echo "diff --git a/$f b/$f"
            diff -u --label "a/$f" --label "b/$f" "$work/base/$f" "$work/new/$f" || true
        done
    } > "$work/regenerated"

    mv "$work/regenerated" "$target"
    rm -f "$state"
    apply_all
    echo "Regenerated $2. Now run: mise run check-patches"
    ;;

*)
    echo "unknown mode: $mode (expected edit or finish)" >&2
    exit 2
    ;;
esac
