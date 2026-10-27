#!/usr/bin/env bash
# lumen-stats: everything measurable about the running Lumen daemon.
#
#   tools/lumen-stats.sh               snapshot + CPU while idle (10 s)
#   tools/lumen-stats.sh --scenario    also drives the window (shows it, types
#                                      queries in every view, hides it) and
#                                      measures CPU and GPU during that
#
# Inside the process: `lumen --stats` (latency to painted frame, heap, index
# numbers). From outside: /proc (memory by kind of mapping, CPU per named
# thread) and nvidia-smi (VRAM, SM usage).

set -euo pipefail

LUMEN=${LUMEN:-lumen}
IDLE_SECS=${IDLE_SECS:-10}
PID=$(pgrep -x lumen-gtk | head -1 || true)
[[ -n "$PID" ]] || { echo "lumen is not running" >&2; exit 1; }
TCK=$(getconf CLK_TCK)

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------- memory
memory() {
    section "Memory by kind of mapping (from /proc/$PID/smaps)"
    printf '  %9s %9s %10s   %s\n' "RSS MB" "PSS MB" "private MB" "kind"
    awk '
        /^[0-9a-f]+-[0-9a-f]+ / {
            path = (NF >= 6) ? $6 : "[anon]"
            if (path ~ /files\.idx/)            kind = "file index (mmap)"
            else if (path ~ /content\.idx/)     kind = "content index (mmap)"
            else if (path ~ /^\/dev\/nvidia|nvidia|libGLX|libEGL|libvulkan|libgbm|libdrm/) kind = "GPU driver"
            else if (path ~ /libgtk|libgdk|libgsk|libpango|libcairo|libharfbuzz|libglib|libgio|libgobject|libgraphene|libfreetype|libfontconfig/) kind = "GTK + GLib libs"
            else if (path ~ /\.so/)            kind = "other libs"
            else if (path ~ /lumen$/)          kind = "lumen binary"
            else if (path ~ /\[heap\]|\[anon\]|^$/) kind = "heap + anonymous"
            else if (path ~ /\[stack/)         kind = "stacks"
            else if (path ~ /\.cache|fontconfig|\.mo$|icon|\.ttf|\.otf|\.woff/) kind = "caches, fonts, icons"
            else kind = "other"
            next
        }
        /^Rss:/          { rss[kind] += $2 }
        /^Pss:/          { pss[kind] += $2 }
        /^Private_Dirty:/{ priv[kind] += $2 }
        /^Private_Clean:/{ priv[kind] += $2 }
        END {
            for (k in rss) printf "  %9.1f %9.1f %10.1f   %s\n", rss[k]/1024, pss[k]/1024, priv[k]/1024, k
        }' "/proc/$PID/smaps" | sort -rn
    awk '/^(Rss|Pss|Private_Clean|Private_Dirty|Swap):/ { v[$1] = $2 }
         END { printf "  total: RSS %.1f MB, PSS %.1f MB, USS (private) %.1f MB, swap %.1f MB\n", v["Rss:"]/1024, v["Pss:"]/1024, (v["Private_Clean:"]+v["Private_Dirty:"])/1024, v["Swap:"]/1024 }' \
        "/proc/$PID/smaps_rollup"
    grep -E 'VmHWM' "/proc/$PID/status" | awk '{ printf "  peak RSS since start: %.1f MB\n", $2/1024 }'
}

# ------------------------------------------------------------------ disk
disk() {
    section "Disk"
    local cache=${XDG_CACHE_HOME:-$HOME/.cache}/lumen data=${XDG_DATA_HOME:-$HOME/.local/share}/lumen
    for f in "$cache/files.idx" "$cache/content.idx" "$data/lumen.db"; do
        [[ -e "$f" ]] && printf '  %-48s %8.1f MB\n' "${f/#$HOME/\~}" "$(stat -c %s "$f" | awk '{print $1/1048576}')"
    done
    [[ -d "$cache/text" ]] && printf '  %-48s %8.1f MB (%d files)\n' "${cache/#$HOME/\~}/text (extracted)" \
        "$(du -sb "$cache/text" | awk '{print $1/1048576}')" "$(ls "$cache/text" | wc -l)"
    printf '  %-48s %8.1f MB\n' "binary $(command -v "$LUMEN")" "$(stat -c %s "$(command -v "$LUMEN")" | awk '{print $1/1048576}')"
}

# -------------------------------------------------------------- threads
# "tid name ticks" for every thread.
thread_ticks() {
    for t in /proc/$PID/task/*; do
        [[ -r $t/stat ]] || continue
        # comm may contain spaces: take what is between the parens.
        local stat name rest
        stat=$(<"$t/stat") || continue
        name=${stat#*(}; name=${name%%)*}
        rest=${stat##*) }
        read -r -a f <<<"$rest"
        echo "${t##*/} ${name// /_} $(( f[11] + f[12] ))"
    done
}

# CPU per thread between two thread_ticks snapshots over $3 seconds.
cpu_delta() {
    local before=$1 after=$2 secs=$3
    awk -v secs="$secs" -v tck="$TCK" '
        NR == FNR { b[$1] = $3; next }
        { d = $3 - (($1 in b) ? b[$1] : 0); name[$2] += d; total += d }
        END {
            for (n in name) if (name[n] > 0) printf "  %-18s %8.1f ms  %6.2f %% of a core\n", n, name[n]*1000/tck, name[n]*100/tck/secs
            printf "  %-18s %8.1f ms  %6.2f %% of a core\n", "TOTAL", total*1000/tck, total*100/tck/secs
        }' "$before" "$after" | sort -k2 -rn
}

threads() {
    section "Threads"
    thread_ticks | awk '{ n[$2]++ } END { for (k in n) printf "  %-18s x%d\n", k, n[k] }' | sort
}

# ------------------------------------------------------------------ GPU
gpu() {
    section "GPU (nvidia-smi)"
    if ! command -v nvidia-smi >/dev/null; then echo "  nvidia-smi not found"; return; fi
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader | sed 's/^/  /'
    local line
    line=$(nvidia-smi pmon -c 1 -s um 2>/dev/null | awk -v p="$PID" '$2 == p')
    if [[ -n "$line" ]]; then
        awk '{ printf "  VRAM %s MiB   SM %s%%   memory controller %s%%   (type %s)\n", $9, $4, $5, $3 }' <<<"$line"
    else
        echo "  lumen holds no GPU context right now"
    fi
}

# --------------------------------------------------------------- idle CPU
idle_cpu() {
    section "CPU while idle (${IDLE_SECS}s, window hidden)"
    local a b
    a=$(mktemp) b=$(mktemp)
    thread_ticks >"$a"; sleep "$IDLE_SECS"; thread_ticks >"$b"
    cpu_delta "$a" "$b" "$IDLE_SECS"
    rm -f "$a" "$b"
}

# -------------------------------------------------------------- scenario
scenario() {
    section "Scenario: show, type in every view, hide (x3)"
    local a b pm t0 t1
    a=$(mktemp) b=$(mktemp) pm=$(mktemp)
    nvidia-smi pmon -d 1 -s um 2>/dev/null >"$pm" &
    local pmon=$!
    thread_ticks >"$a"; t0=$(date +%s%N)
    for _ in 1 2 3; do
        "$LUMEN" --show; sleep 0.3
        for q in f fi fir fire firef firefox; do "$LUMEN" --query "$q"; sleep 0.08; done
        for q in 2+2 "10 km to mi"; do "$LUMEN" --query "$q"; sleep 0.1; done
        for q in ma mai main main.z main.zig; do "$LUMEN" --view files --query "$q"; sleep 0.1; done
        for q in Arena ArenaAlloc ArenaAllocator TODO useState "fn main"; do "$LUMEN" --view contents --query "$q"; sleep 0.15; done
        "$LUMEN" --view clipboard; sleep 0.2
        "$LUMEN" --view windows; sleep 0.2
        "$LUMEN" --hide; sleep 0.3
    done
    t1=$(date +%s%N); thread_ticks >"$b"
    kill "$pmon" 2>/dev/null || true; wait "$pmon" 2>/dev/null || true
    local secs; secs=$(awk -v a="$t0" -v b="$t1" 'BEGIN { printf "%.2f", (b-a)/1e9 }')
    echo "  ${secs}s of interaction; CPU by thread:"
    cpu_delta "$a" "$b" "$secs"
    awk -v p="$PID" '$2 == p && $4 != "-" { n++; s += $4; if ($4 > m) m = $4; if ($9 > fb) fb = $9 }
         END { if (n) printf "  GPU: SM avg %.1f%% max %d%% over %d samples, VRAM up to %s MiB\n", s/n, m, n, fb;
               else print "  GPU: SM below 1% in every sample" }' "$pm"
    rm -f "$a" "$b" "$pm"
}

section "Inside the daemon (lumen --stats)"
"$LUMEN" --stats | sed 's/^/  /'
memory
disk
threads
gpu
idle_cpu
if [[ ${1:-} == --scenario ]]; then
    scenario
    section "Latency after the scenario (lumen --stats)"
    "$LUMEN" --stats | sed -n '/^Latency/,$p' | sed 's/^/  /'
fi
