#!/usr/bin/env bash
# Verify that every function the ABI header declares is defined somewhere in core/.
#
# A missing definition is a link error, not a compile error, so nothing that stops
# at the translation unit can see it — and each consumer of the library discovers it
# separately, twenty minutes into a build on a machine that isn't this one. This is
# the same check in under a second, and it needs nothing built.
#
# It caught a real one: an edit that replaced a range of the implementation file
# from one function to another took an unrelated function out with it, and both
# translation units still compiled cleanly.
set -euo pipefail

cd "$(dirname "$0")/.."

header=core/include/slicepad.h
sources=(core/src/*.cpp)

# Declarations look like `<type> sp_name(...);` with the name last on its line
# before the paren. Definitions are the same without the semicolon, at column zero.
declared=$(grep -oE '\bsp_[a-z0-9_]+\(' "$header" | tr -d '(' | sort -u)
defined=$(grep -hoE '^[A-Za-z_][A-Za-z0-9_ *]*\bsp_[a-z0-9_]+\(' "${sources[@]}" \
          | grep -oE 'sp_[a-z0-9_]+\(' | tr -d '(' | sort -u)

missing=$(comm -23 <(echo "$declared") <(echo "$defined"))

if [ -n "$missing" ]; then
    echo "declared in $header with no definition in core/src:" >&2
    echo "$missing" | sed 's/^/  /' >&2
    exit 1
fi

echo "abi: $(echo "$declared" | wc -l | tr -d ' ') declared functions, all defined"
