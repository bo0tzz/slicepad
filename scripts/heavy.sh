#!/usr/bin/env bash
# Run a memory-hungry build as the kernel's preferred OOM victim, so that when
# a compile fans out too far it dies instead of something that matters.
#
#   scripts/heavy.sh cmake --build ...
#
# Raising oom_score_adj needs no privileges (only lowering it does), and the
# setting is inherited by every child, so the whole compile tree is covered.
set -euo pipefail

if [ $# -eq 0 ]; then
    echo "usage: ${BASH_SOURCE[0]} <command> [args...]" >&2
    exit 2
fi

if command -v choom >/dev/null 2>&1; then
    exec choom -n 1000 -- "$@"
fi

if [ -w /proc/self/oom_score_adj ]; then
    echo 1000 > /proc/self/oom_score_adj
else
    echo "warning: cannot raise oom_score_adj; running unprotected" >&2
fi
exec "$@"
