#!/usr/bin/env bash
# Run a heavy build without making the machine unpleasant to use.
#
#   scripts/heavy.sh cmake --build ...
#
# Three layers, because they solve different problems:
#
#   - A systemd scope with MemoryHigh/MemoryMax confines the build to its own
#     cgroup, so it is throttled and then capped inside its own budget rather
#     than competing with the desktop for all of RAM. This is what keeps the
#     machine usable.
#   - oom_score_adj 1000 decides who dies if memory runs out anyway despite the
#     above — the build, never the session.
#   - CPUWeight/IOWeight/nice keep interactive work ahead in the queue.
#
# Tunable: HEAVY_MEM_HIGH, HEAVY_MEM_MAX, HEAVY_NICE, HEAVY_WEIGHT.
set -euo pipefail

if [ $# -eq 0 ]; then
    echo "usage: ${BASH_SOURCE[0]} <command> [args...]" >&2
    exit 2
fi

mem_high=${HEAVY_MEM_HIGH:-8G}
mem_max=${HEAVY_MEM_MAX:-12G}
# Swap needs a cap, but not a tight one. Uncapped, MemoryHigh throttling turns
# into thrashing: one attempt peaked at 8G resident against 16.6G of swap. A 2G
# cap then pegged immediately and throttled the build to a standstill instead.
mem_swap_max=${HEAVY_MEM_SWAP_MAX:-8G}
nice_level=${HEAVY_NICE:-19}
weight=${HEAVY_WEIGHT:-20}

# Raising oom_score_adj needs no privileges, and every child inherits it.
if [ -w /proc/self/oom_score_adj ]; then
    echo 1000 > /proc/self/oom_score_adj
else
    echo "heavy: cannot raise oom_score_adj; running unprotected" >&2
fi

if systemd-run --user --scope --quiet -- true >/dev/null 2>&1; then
    # Named so the exit can be explained. When the budget is hit the kernel kills a
    # compiler inside the cgroup, and the build tool reports that as something else
    # entirely — ninja says "interrupted by user", which sends you looking for a
    # stray Ctrl-C instead of at the memory cap that is doing its job.
    scope="slicepad-heavy-$$"
    set +e
    systemd-run --user --scope --quiet --collect --unit="$scope" \
        -p MemoryHigh="$mem_high" \
        -p MemoryMax="$mem_max" \
        -p MemorySwapMax="$mem_swap_max" \
        -p CPUWeight="$weight" \
        -p IOWeight="$weight" \
        -- nice -n "$nice_level" "$@"
    status=$?
    set -e

    if [ "$status" -ne 0 ] &&
       journalctl --user -u "$scope.scope" -n 20 --no-pager 2>/dev/null | grep -q "oom-kill"; then
        echo "heavy: the build hit its ${mem_max} budget and the kernel killed part of it." >&2
        echo "heavy: this is the cap working, not a broken build. Either run fewer" >&2
        echo "heavy: parallel jobs (-j4 rather than -j\$(nproc); LTO links are the" >&2
        echo "heavy: expensive ones) or raise HEAVY_MEM_MAX if the machine has room." >&2
    fi
    exit "$status"
fi

echo "heavy: no usable systemd user scope; memory will not be capped" >&2
exec nice -n "$nice_level" "$@"
