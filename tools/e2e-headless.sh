#!/usr/bin/env bash
# Runs the end-to-end suite (or any command) in a Wayland session of its
# own, with no screen: a headless sway (layer-shell, which Lumen's window
# needs), software rendering, its own XDG_RUNTIME_DIR and D-Bus session. CI
# runs it; on a desktop it leaves the session it is started from alone.
#
#   tools/e2e-headless.sh [command...]     (default: zig build e2e)
#
# Needs sway and dbus-run-session. PERF_SCALE goes on to tools/e2e.sh: set it
# where software rendering is slow (CI does).

set -uo pipefail

for tool in sway dbus-run-session; do
    command -v "$tool" >/dev/null || { echo "e2e-headless: $tool is not installed" >&2; exit 2; }
done
(($# > 0)) || set -- zig build e2e

R=$(mktemp -d "${TMPDIR:-/tmp}/lumen-e2e-session.XXXXXX") || { echo "e2e-headless: mktemp failed" >&2; exit 2; }
[[ -n "$R" && -d "$R" ]] || { echo "e2e-headless: mktemp gave no folder" >&2; exit 2; }
chmod 700 "$R"
SWAY=

cleanup() {
    if [[ -n "$SWAY" ]]; then
        kill "$SWAY" 2>/dev/null
        for _ in $(seq 30); do kill -0 "$SWAY" 2>/dev/null || break; sleep 0.1; done
        kill -KILL "$SWAY" 2>/dev/null
        wait "$SWAY" 2>/dev/null
    fi
    rm -rf "$R"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# One virtual monitor; nothing that reads the user's sway config.
cat >"$R/sway.conf" <<'EOF'
output HEADLESS-1 mode 1920x1080 position 0 0
default_border none
xwayland disable
EOF
# A copy of sway, without the capability its package gives it (cap_sys_nice,
# for its priority): a container's bounding set lacks it, and exec refuses
# the binary itself there ("Operation not permitted"), CI's included.
cp "$(command -v sway)" "$R/sway" || { echo "e2e-headless: cannot copy sway" >&2; exit 2; }

# Nothing of the caller's session reaches sway or the command: no display,
# no compositor socket, no session bus (dbus-run-session starts one).
session_env=(env -u WAYLAND_DISPLAY -u DISPLAY -u SWAYSOCK -u HYPRLAND_INSTANCE_SIGNATURE
    -u DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR="$R")
"${session_env[@]}" WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    "$R/sway" --config "$R/sway.conf" >"$R/sway.log" 2>&1 &
SWAY=$!

socket=
for _ in $(seq 100); do
    for candidate in "$R"/wayland-*; do
        [[ -S "$candidate" ]] && { socket=$(basename "$candidate"); break; }
    done
    [[ -n "$socket" ]] && break
    kill -0 "$SWAY" 2>/dev/null || break
    sleep 0.1
done
if [[ -z "$socket" ]]; then
    echo "e2e-headless: sway did not start; its log:" >&2
    cat "$R/sway.log" >&2
    exit 2
fi
echo "e2e-headless: sway on $socket ($R)"

# GTK on the software renderer: no GPU behind the headless output. A UTF-8
# locale, as on a desktop (a container has none): in the C locale GLib
# prints a dmenu line that is not UTF-8 as "[Invalid UTF-8]".
"${session_env[@]}" WAYLAND_DISPLAY="$socket" GDK_BACKEND=wayland GSK_RENDERER=cairo \
    LANG="${LANG:-C.UTF-8}" dbus-run-session -- "$@"
status=$?
if ((status != 0)); then
    echo "e2e-headless: '$*' failed ($status); sway's log:" >&2
    tail -n 50 "$R/sway.log" >&2
fi
exit "$status"
