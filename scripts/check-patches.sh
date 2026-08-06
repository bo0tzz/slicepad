#!/usr/bin/env bash
# Verify that patches/ reproduces the current engine checkout.
#
# The checkout is a build artifact and the patch stack is the source of truth, so
# editing the tree without regenerating a patch leaves a build that works locally
# and fails everywhere else. That is easy to do and expensive to discover: it
# costs a CI round trip to find out.
#
# Works by comparing the tree's current diff against the diff produced by applying
# the stack to a pristine tree. Restores the working tree either way.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
orca="$root/third_party/orcaslicer"
patches="$root/patches"

if [ ! -d "$orca/.git" ]; then
    echo "no engine checkout; run 'mise run fetch' first" >&2
    exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git -C "$orca" diff > "$work/current.patch"

git -C "$orca" checkout -- .
shopt -s nullglob
for p in "$patches"/*.patch; do
    git -C "$orca" apply --whitespace=nowarn "$p"
done
git -C "$orca" diff > "$work/from-stack.patch"

if diff -q "$work/current.patch" "$work/from-stack.patch" >/dev/null; then
    echo "patches/ reproduces the checkout."
    exit 0
fi

echo "MISMATCH: the checkout differs from what patches/ produces." >&2
echo "Either regenerate the patch you edited, or re-run 'mise run fetch'." >&2
diff -u "$work/from-stack.patch" "$work/current.patch" | head -40 >&2
exit 1
