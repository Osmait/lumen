#!/usr/bin/env bash
# Compares `zig build perf` on a base commit with the working tree:
#
#   tools/perf-compare.sh [BASE]          (BASE defaults to origin/main)
#
# Runs both ROUNDS times, alternating, so that whatever else the machine
# does falls on both alike; keeps each check's fastest run, and fails when
# the working tree is slower than the base by more than THRESHOLD times and
# by more than FLOOR (in the check's unit, ms or MB: tiny timings jitter).
# `zig build perf`'s own limits allow 4-5x and catch only gross slowdowns;
# this catches the 25-40% ones (MYP-189).
#
# Environment: PERF_ROUNDS (5), PERF_THRESHOLD (1.25), PERF_FLOOR (0.5).
# PERF_SCALE is passed on to `zig build perf` as usual.

set -euo pipefail

base_ref=${1:-origin/main}
rounds=${PERF_ROUNDS:-5}
threshold=${PERF_THRESHOLD:-1.25}
floor=${PERF_FLOOR:-0.5}

work=$(mktemp -d)
cleanup() {
    git worktree remove --force "$work/base" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
git worktree add --detach "$work/base" "$base_ref" >/dev/null

# One line per check, "name<TAB>value<TAB>unit". A count in the name
# ("(50 hits)") is dropped: it may differ between commits.
checks() {
    sed -nE 's/^  (ok  |FAIL) (.*[^ ]) +([0-9.]+) (ms|MB)  \(limit.*/\2\t\3\t\4/p' "$1" |
        sed -E 's/ \([0-9]+ [a-z]+\)\t/\t/'
}

# `zig build perf` exits 1 when one of its own limits fails: the numbers
# are still printed, and still compared.
for round in $(seq "$rounds"); do
    echo "round $round/$rounds" >&2
    (cd "$work/base" && zig build perf >"$work/base.$round" 2>&1) || true
    zig build perf >"$work/head.$round" 2>&1 || true
done

for side in base head; do
    for round in $(seq "$rounds"); do checks "$work/$side.$round"; done >"$work/$side.tsv"
done

awk -F'\t' -v threshold="$threshold" -v floor="$floor" -v base_ref="$base_ref" '
    FNR == NR {
        if (!($1 in base) || $2 < base[$1]) base[$1] = $2
        next
    }
    {
        if (!($1 in head)) order[++count] = $1
        if (!($1 in head) || $2 < head[$1]) head[$1] = $2
        unit[$1] = $3
    }
    END {
        printf "%-46s %10s %10s %7s\n", "check (fastest of each)", base_ref, "this", "ratio"
        failed = 0
        for (i = 1; i <= count; i++) {
            name = order[i]
            if (!(name in base)) {
                printf "%-46s %10s %10.3f %7s  new\n", name, "-", head[name], "-"
                continue
            }
            ratio = base[name] > 0 ? head[name] / base[name] : 1
            verdict = ""
            if (ratio > threshold && head[name] - base[name] > floor) {
                verdict = "  SLOWER"
                failed++
            }
            printf "%-46s %10.3f %10.3f %6.2fx%s\n", name, base[name], head[name], ratio, verdict
        }
        if (failed > 0) {
            printf "\n%d check(s) slower than %s by more than %sx\n", failed, base_ref, threshold
            exit 1
        }
        printf "\nno check slower than %s by more than %sx\n", base_ref, threshold
    }
' "$work/base.tsv" "$work/head.tsv"
